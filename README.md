# super-board

An autonomous GitHub Project board executor for Claude Code. Drag a card into the `Ready` column, walk away, come back to merged PRs.

Super Board watches your GitHub Project, dispatches headless `claude -p` workers to Build / QA / Review the cards, and moves each card across the board as it goes — all without holding a single Claude session open.

## Watch it run

[![Watch the super-board walkthrough on YouTube](https://img.youtube.com/vi/nX_bGyIOFM4/maxresdefault.jpg)](https://youtu.be/nX_bGyIOFM4)

▶ [https://youtu.be/nX_bGyIOFM4](https://youtu.be/nX_bGyIOFM4)

## Quickstart

1. Download the latest release zip from [Releases](../../releases/latest).
2. Unzip into your project's `.claude/` directory:
   ```bash
   cd your-project
   unzip ~/Downloads/super-board-v*.zip -d .claude/
   ```
3. Wire up a GitHub Project board with a `Status` field whose columns are `Backlog`, `Ready`, `Building`, `QA`, `Review`, `Done`.
4. Drop a config at `.claude/super-board/configs/<slug>.json` pointing at your board.
5. From inside Claude Code, type `/super-board run <slug>`. The orchestrator spawns the headless runner, prints a PID + log path, and exits.

That's it. Move cards into `Ready`, watch them flow through the board.

To stop everything cleanly: `/super-board stop`. It posts a "stopped mid-flight" comment on every in-flight issue + PR (lane, last commit, resume hint), releases the assignee mutex, kills the workers and dispatcher. To resume, just `/super-board run <slug>` again — the board is the state, so cards are picked up from whichever column they were in.

## How it works

There are four skills in this repo:

| Skill | Role |
|---|---|
| **super-board** | The orchestrator. Invoked by the human via `/super-board run`. Validates preconditions, dispatches the headless runner (`scripts/super-board-run.sh`), and exits. Holds NO product context. |
| **super-build** | Headless worker. Reads a `Ready` card, spins up a git worktree, implements the change, opens a PR, moves the card to `QA`. |
| **super-qa** | Headless worker. Reads a `QA` card, runs Playwright path specs against the worker's branch, captures evidence (screenshots, logs), comments on the PR, and either moves the card to `Review` or kicks it back to `Ready` with a rebuild label. |
| **super-review** | Headless worker. Reads a `Review` card, runs the merge-readiness checks, posts findings, and either merges (or hands off to a human gate). |

The runner (`scripts/super-board-run.sh`) is pure bash. It re-reads the GitHub Project on every tick — it holds no Claude session state, so it survives Ctrl-C, restarts, and rate-limit pauses without losing track of cards.

## Safety controls

Worker storms are the failure mode that bit early users. Super Board prevents them with defense in depth:

1. **Orphan scan** on startup — refuses to run if any `super-board` workers are already alive from a prior crashed run.
2. **In-flight lockfiles** at `.claude/super-board/inflight/<issue-N>` — survive runner restart and gate `top_card_in_column` even when GitHub state hasn't propagated.
3. **Atomic assignee claim BEFORE worker spawn** — closes the 10–30s `claude -p` cold-start race.
4. **One worker per lane** — at most one Builder, one Tester, one Reviewer at a time. A 30-card `Ready` backlog does NOT start 30 Builders.
5. **GraphQL rate-limit guard** — sleeps until reset when remaining quota dips under 200.
6. **120-second tick** — keeps ProjectsV2 query cost (~103 GraphQL pts/tick) at ~3.1k/hr, well under the 5k budget. Bump in your config if you have more headroom.

## Configuration

Minimal config at `.claude/super-board/configs/<slug>.json`:

```json
{
  "variant": "full",
  "project": { "owner": "your-gh-login-or-org", "number": 12 },
  "base_branch": "main",
  "human_approves_merge": false,
  "rebuild_cap": 2,
  "tick_seconds": 120,
  "max_workers": 3,
  "notifications": { "bot_identity": "your-bot-login" }
}
```

Variants:
- `full` — Build + QA + Review (3 lanes, max 3 workers)
- `qa-only` — QA + Review only (2 lanes, max 2 workers). Useful for hardening already-built code.

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (the host that loads the skills)
- `gh` CLI authenticated against the GitHub org/account that owns the Project board
- `jq`
- `bash` 4+
- A GitHub Project (v2) with a `Status` single-select field

## Skill structure

Each skill lives under `skills/<name>/` with a `SKILL.md` (the agent-facing prompt) and optional `references/` and `scripts/` directories. Drop the whole `.claude/` tree into your project and Claude Code picks them up automatically.

## What this is NOT

- Not a CI replacement. Workers commit and push branches; your existing CI still runs.
- Not a free pass on review. Set `human_approves_merge: true` if you want a person to OK every merge.
- Not for unreviewed AC-free issues. Cards need acceptance criteria — Super QA grades against them.

## Licence

MIT. See [LICENSE](./LICENSE).

## Credits

Designed and maintained by Eric Tech. Skill structure inspired by [obra/superpowers](https://github.com/obra/superpowers).
