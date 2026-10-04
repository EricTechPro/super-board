---
name: git-sync
description: Sync the current branch in one pass — commit the working tree as one commit per logical change (in the host repo's commit format, or the super-board writing standard), gate Supabase schema changes, merge-pull, resolve conflicts hunk by hunk, then push without force. Use when the user runs /git-sync or says "git-sync", "sync", "commit and push", "pull and push", or "sync my branch".
---

# /git-sync

Commit what is in the working tree, pull, push, report. One step per line.
Stop and tell the user when a step says stop. NEVER force push, rebase shared history, or
skip a hook (`--no-verify`).

## 1 · Look

1. Run `git status`, `git branch --show-current` and `git rev-parse --abbrev-ref @{upstream}`.
2. Run `git fetch` and `git rev-list --left-right --count HEAD...@{upstream}` for ahead/behind.
3. Stop on a detached HEAD.
4. Stop when a merge, rebase, cherry-pick or revert is in progress that this run did not start
   (`.git/MERGE_HEAD`, `.git/rebase-merge`, `.git/rebase-apply`, `.git/CHERRY_PICK_HEAD`).
5. Nothing to commit and nothing ahead or behind: say "in sync" and stop.

## 2 · Commit

1. Read the diff (`git diff`, `git diff --staged`, untracked files) and group it into logical
   changes. One change, one commit.
2. Stage each group by explicit path (`git add -- <path>…`). NEVER `git add -A`, `git add .`
   or `git commit -a`.
3. NEVER stage secrets: `.env*` (except `.env.example`), keys (`*.pem`, `*.key`, `id_rsa*`),
   credential or token files, or a diff line that holds a key. Stop and warn, naming the file.
4. A file that looks like someone else's work in progress (another task's half-edit, a file
   you can't explain from this conversation): leave it unstaged and list it in the report.
5. Changes already staged by the user are one group; commit them as they are.
6. Run the Supabase gate (section 3) before any commit that touches `supabase/`.
7. Commit each group. Let the hooks run; a failing hook is a stop, not a retry with
   `--no-verify`.

**Commit format.** The host wins.

1. The host's `AGENTS.md`, `CLAUDE.md` or `CONTRIBUTING.md` defines a commit format: follow it
   (for example `#N: type: description`).
2. Otherwise use section "1 · Commit" of the super-board writing standard
   (`.claude/skills/super-board/references/writing-standard.md`): emoji, `[type]`, scope,
   subject, 1–4 bullets, `Closes #N` when the commit finishes a ticket.
3. Keep any attribution trailer the session asks for.

## 3 · Supabase gate

Runs only when a commit group touches `supabase/` (migrations, schema, functions).

1. The `supabase` skill is installed: follow its "Making and Committing Schema Changes" section
   and skip the rest of this list.
2. Each schema change has its own migration file named the way `supabase migration new <name>`
   names it (`supabase/migrations/<timestamp>_<name>.sql`). A schema edit with no migration is
   a stop.
3. When the CLI and local stack are up, run `supabase migration list --local`.
4. Run `supabase db advisors` (or the Supabase MCP `get_advisors`) when available.
5. An advisor error is a stop. Warnings go in the report.
6. CLI or stack not available: say which checks were skipped and why, then continue.

## 4 · Pull

1. Run `git pull --no-rebase`. Merge, never rebase.
2. No conflict: go to Push.
3. Conflict: use the `resolving-merge-conflicts` skill when it is installed.
4. Without it, resolve hunk by hunk and keep both sides' intent.
5. NEVER use `-X ours`, `-X theirs`, `git checkout --ours/--theirs` on a whole file, or delete
   a side to make the conflict go away.
6. A hunk whose intent is unclear: stop and ask the user, showing both sides.
7. Run the host's fast checks before concluding the merge: typecheck, lint and tests as the
   host's `AGENTS.md`, `CLAUDE.md` or `package.json` documents them.
8. Checks fail: fix the merge, not the checks. Still failing: stop and report.
9. Conclude with `git commit --no-edit`.

## 5 · Push

1. The branch has an upstream: `git push`.
2. A new branch: `git push -u origin <branch>`.
3. NEVER `--force` or `--force-with-lease`.
4. The branch is the default or a protected branch (`main`, `master`, `production`, or the
   repo's default from `gh repo view --json defaultBranchRef`): push only after the user says
   yes in this conversation. Otherwise offer a branch and a PR instead.
5. Push rejected as non-fast-forward: go back to Pull once. Rejected again: stop.

## 6 · Report

Keep it short:

```
Committed  <sha> <subject>
           <sha> <subject>
Pulled     <N> commits (<conflicts resolved: N files | no conflicts>)
Pushed     <N> commits to <remote>/<branch>
Left out   <path> — <why>
Supabase   <advisors clean | N warnings | skipped: why>
```

Drop the lines that do not apply.
