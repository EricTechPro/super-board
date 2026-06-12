# super-board

An autonomous GitHub Project board executor for Claude Code. Drag a card into the `Ready` column, walk away, come back to merged PRs.

Super Board watches your GitHub Project, dispatches agents to Build / QA / Review the cards, and moves each card across the board as it goes. Default backend: dynamic workflows (in-session waves); a legacy headless `claude -p` dispatcher remains as explicit opt-in.

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
5. From inside Claude Code, type `/super-board run <slug>`. The orchestrator plans a wave, launches the `super-board-wave` dynamic workflow, reconciles results, and repeats until the board is drained.

That's it. Move cards into `Ready`, watch them flow through the board.

**Backends (default flipped in 1.6.0):** `"worker_backend": "workflow"` is the default — waves are drained in-session via dynamic workflows (requires dynamic workflows enabled in `/config`); see `skills/super-board/references/run-workflow.md`. The legacy headless dispatcher (`"claude-p"`, `claude -p` workers spawned by `scripts/super-board-run.sh`) is explicit opt-in only — the dispatcher refuses to run (exit 78) unless the config sets it. Lane lifecycles are identical in both.

To stop everything cleanly: `/super-board stop`. It posts a "stopped mid-flight" comment on every in-flight issue + PR (lane, last commit, resume hint), releases the assignee mutex, kills the workers and dispatcher. To resume, just `/super-board run <slug>` again — the board is the state, so cards are picked up from whichever column they were in.

## How it works

There are four skills in this repo:

| Skill | Role |
|---|---|
| **super-board** | The orchestrator. Invoked by the human via `/super-board run`. Validates preconditions, plans waves, launches the `super-board-wave` workflow (or the legacy headless runner on opt-in). Holds NO product context. |
| **super-build** | Builder lane agent. Reads a `Ready` card, spins up a git worktree, implements the change, opens a PR, moves the card to `QA`. |
| **super-qa** | Tester lane agent. Reads a `QA` card, runs Playwright path specs against the worker's branch, captures evidence (screenshots, logs), comments on the PR, and either moves the card to `Review` or kicks it back to `Ready` with a rebuild label. |
| **super-review** | Reviewer lane agent. Reads a `Review` card, runs the merge-readiness checks, posts findings, and either merges (or hands off to a human gate). |

The three lane skills run as workflow agents inside `super-board-wave` by default; on the legacy `claude-p` backend the same skills run as headless `claude -p` workers. Same lifecycles either way.

## The five verbs

| Verb | What it does |
|---|---|
| `/super-board onboard` | One-time setup wizard — points at your GitHub Project, checks the `Status` columns, writes `.claude/super-board/configs/<slug>.json`. |
| `/super-board lint` | Pre-flight readiness — walks the active-pipeline issues, flags vague or missing acceptance criteria before agents burn tokens on them. |
| `/super-board status` | Read-only snapshot — renders the board as an 80-column kanban with column counts and in-flight work (~1.3s, pure Python). |
| `/super-board run <slug>` | The autonomous loop — plans waves, dispatches lane agents, repeats until the board is drained. Also the resume command: state lives on the board, so re-running picks up where things left off. |
| `/super-board stop` | Graceful shutdown — posts "stopped mid-flight" comments on every in-flight issue + PR, releases assignee mutexes, kills any workers. Resume with `run`. |

The board is the only state in both backends — every agent re-reads it, so runs survive Ctrl-C, restarts, and rate-limit pauses without losing track of cards.

## The six agentic patterns, mapped

The patterns live in the workflow script (`workflows/super-board-wave.js`) — the conductor. The skills (`super-build` / `super-qa` / `super-review`) are the sheet music each lane agent reads. The workflow spawns a fresh agent per lane whose prompt says: *"Run super-build on issue #N, follow run.md's Builder lifecycle exactly."*

One card's journey (#47, starting in `Ready`):

```
            ┌─ ROUTING ─────────────┐
 #47 Ready →│ classify agent (haiku)│→ "bug, low" → cheap model for lanes
            └───────────────────────┘
                       ↓
            ┌─ PROMPT CHAINING ──────────────────────────────────┐
            │ Build agent ──advanced?──→ QA agent ──→ Review agent│
            │ (super-build)   │no        (super-qa)  (super-review)│
            │                 ↓                                    │
            │           chain stops; the board keeps the card      │
            └─────────────────────────────────────────────────────┘
```

A wave (3 cards at once):

```
 ORCHESTRATOR (your session)           ← orchestrator–workers
   │ plan wave → claim → launch
   ▼
 #47: classify → build → qa → review   ┐
 #51:           qa → review            ├ parallelization (cards overlap)
 #52: classify → build ✗(bounced)      ┘
                          │
 Review lanes: ──[mutex]── one merge at a time
```

When each pattern fires:

| Pattern | When |
|---|---|
| **Routing** | `Ready` cards only — classify picks haiku/sonnet/full model per card |
| **Prompt chaining** | Every card — each lane runs only if the previous returned `advanced` |
| **Parallelization** | Always — card A can be in Review while card B builds |
| **Evaluator–optimizer** | QA/Review judge the Builder's work; a fail bounces the card to `Ready` and the next wave rebuilds with the comments as context |
| **Orchestrator–workers** | Every wave — your session never codes; lane agents do all product work |
| **Autonomous loop** | The wave loop repeats until the board is drained or a halt gate fires |

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
  "worker_backend": "workflow",
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
