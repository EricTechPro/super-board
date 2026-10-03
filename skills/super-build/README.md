# /super-build

The Builder: turns a `Ready` card into a branch, the smallest safe change, tests and a draft PR.

## What It Does

- **Works in its own git worktree** on `issue-<N>-<slug>`, and picks up an existing branch if a stopped run left one.
- **Routes skills by the card's type label**: `bug` → `diagnosing-bugs` + `tdd`, `feature` → `implement` + `tdd` + `codebase-design`, `refactor`/`tech-debt` → `codebase-design` + `tdd`, `docs` skips `tdd`. A `Skills:` line in the card overrides the row.
- **Simplest solution first**: runs `ponytail:ponytail` before the first line of code, or an inline ladder when the plugin is absent. Validation, security, data-loss protection and accessibility are never cut.
- **Reads official docs first** when a card touches a third-party API or SDK, an upgrade, or auth/billing, and lists them as `Docs:` bullets in the PR's Solution block.
- **On a rebuild** it fixes every `[builder]` review thread and the Tester's latest failure, and fixes the code, not just the thread.
- **Never merges.** Merging belongs to the Reviewer and the merge gate.

## When To Use It

- Inside a super-board run (the Building lane). This is the normal path.
- Standalone, as `/super-build` (legacy, opt-in), to drain the `Ready` column of a project with headless `claude -p` workers (3 at a time unless `max_workers` is set); each finished branch becomes a PR and its card moves to `QA`.

## Standalone flags

| Command | Does |
|---|---|
| `/super-build` | Process every `Ready` issue in board order |
| `/super-build --only N` | Execute only issue #N |
| `/super-build --dry-run` | Print the dispatch plan, change nothing |

## Install

Part of the super-board pack: `./install.sh /path/to/project`. Lane details: `skills/super-board/references/run.md` → Builder.
