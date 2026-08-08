# super-board

An autonomous GitHub Project board executor for Claude Code. Drag a card into the `Ready` column, walk away, come back to merged PRs.

## At a glance

| | |
|---|---|
| **What it does** | Watches a GitHub Project, runs Build → QA → Review per card, merges when green |
| **What you get** | Merged PRs with evidence — screenshots, test reruns, review findings on the PR |
| **How you start** | `/super-board run <slug>` — drag cards into `Ready`, walk away |
| **What holds state** | The board itself. Ctrl-C, restart, resume — cards pick up from their column |
| **Backend** | Dynamic workflows (in-session waves) by default; headless `claude -p` on opt-in |

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

**Backends** — lane lifecycles are identical in both:

| | `workflow` (default since 1.6.0) | `claude-p` (opt-in) |
|---|---|---|
| Runs as | in-session dynamic workflow waves | headless `claude -p` workers |
| Needs | dynamic workflows on in `/config` | nothing extra |
| Reference | `skills/super-board/references/run-workflow.md` | `scripts/super-board-run.sh` |

The legacy dispatcher refuses to run (exit 78) unless the config explicitly sets it.

**Stop and resume** — `/super-board stop` posts a "stopped mid-flight" comment on every in-flight issue and PR (lane, last commit, resume hint), releases the assignee mutex, kills workers and dispatcher. Resume with `/super-board run <slug>`: the board is the state, so cards pick up from whichever column they were in.

## How it works

```
  Backlog → Ready ─────→ Building ─────→ QA ──────────→ Review ────→ Done
                             │             │                │          ▲
                        super-build     super-qa      super-review     │
                        worktree+PR     evidence      merge gate       │
                             │             │                │     squash-merge
                             └─────────────┴────────────────┘
                                  bounce back on failure

  ORCHESTRATOR (super-board) — plans waves, holds no product context, writes no code
```

| Skill | Lane | Does |
|---|---|---|
| **super-board** | — | Orchestrator. Validates preconditions, plans waves, launches them. Holds NO product context. |
| **super-build** | `Ready` → `QA` | Spins up a git worktree, implements the change, opens a PR. |
| **super-qa** | `QA` → `Review` | Crawls routes, captures screenshots/logs/HARs, comments on the PR, or bounces the card back with a rebuild label. |
| **super-review** | `Review` → `Done` | Re-runs the Tester's tests, adversarial truth-check, merges or hands to a human gate. |

Lane skills run as workflow agents inside `super-board-wave` by default, or as headless `claude -p` workers on the legacy backend. Same lifecycles either way.

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

```
  workflows/super-board-wave.js   the conductor — owns the patterns
  skills/super-{build,qa,review}  the sheet music — one lane agent each
  the prompt it spawns            "Run super-build on #N, follow run.md exactly"
```

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

**Worker storms** are the failure mode that bit early users — 30 `Ready` cards
starting 30 Builders. Six gates stand between you and that:

```
  spawn a worker?
       │
       ├─ 1  orphan scan ........... workers alive from a crashed run?  → refuse
       ├─ 2  in-flight lockfile .... .claude/super-board/inflight/<N>   → skip
       │       survives restart; gates the column even before GitHub catches up
       ├─ 3  assignee claim ........ atomic, BEFORE spawn               → skip
       │       closes the 10-30s claude -p cold-start race
       ├─ 4  lane occupied? ........ 1 Builder · 1 Tester · 1 Reviewer  → wait
       ├─ 5  GraphQL quota <200 .... sleep until reset                  → wait
       └─ 6  tick not elapsed? ..... 120s floor                         → wait
       │
       ▼  all six clear
     spawn
```

The 120-second tick holds ProjectsV2 query cost (~103 GraphQL pts/tick) to
~3.1k/hr against a 5k budget. Raise `tick_seconds` in your config if you have
headroom.

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

```
  variant               full | qa-only
  worker_backend        workflow | claude-p
  human_approves_merge  true = never auto-merge, always hand to you
  rebuild_cap           bounces allowed before a card goes Blocked
  tick_seconds          GraphQL budget floor — raise if you have headroom
  max_workers           one per lane; 3 for full, 2 for qa-only
```

```
  variant       lanes                                    max workers
  ─────────     ─────────────────────────────────────    ───────────
  full          Ready → Building → QA → Review → Done         3
  qa-only              Ready → QA → Review → Done              2
                       └ hardening code that already exists
```

## How workers decide what test to write

Three layers, three different questions. None substitutes for another.

```
  tdd          →  how do I write a test worth having?     discipline
  the ladder   →  which layer does the defect live at?    placement
  vitest |        how do I express it in this repo?       mechanics
  playwright
```

**The middle one is what everyone skips.** A Tester finds every bug through a
browser — that is what a route crawler does. Where you *observed* a bug says
nothing about where it *lives*.

```
  ┌─ found here ─┐
  │   browser    │  every bug-bash finding enters at the top
  └──────┬───────┘
         │   walk DOWN — stop at the first rung that still reproduces
         ▼
  ╔═══════════════════════════════════╤══════════════╤═════════════╗
  ║ 1  call the module directly       │ unit         │ Vitest      ║
  ║ 2  wire the real collaborators    │ integration  │ Vitest      ║
  ║ 3  drive a real browser           │ e2e          │ Playwright  ║
  ║ 4  needs a live third party       │ NOT a test   │ file a gap  ║
  ╚═══════════════════════════════════╧══════════════╧═════════════╝
         ▲
         └── write it HERE, not where you found it
```

Locality of failure is the point: an e2e pinning a pure-logic defect is slower,
flakier, and goes red pointing at a page instead of a function — so the next
person debugs the wrong file.

```
  ✓ red for the right reason   run against UNFIXED code — a timeout or missing
                               selector means you pinned the harness, not the bug
  ✓ refactor-survivable        behaviour-preserving rewrite must still pass
```

`testing-strategy` informs *coverage* — what a component type is worth testing,
what to skip. It does not decide placement; the ladder does. Contract testing
stays out of the default set: Pact solves consumer/provider drift across
independently deployed services, which a single-app repo does not have.

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (the host that loads the skills)
- `gh` CLI authenticated against the GitHub org/account that owns the Project board
- `jq`
- `bash` 4+
- A GitHub Project (v2) with a `Status` single-select field

## Skill structure

```
  skills/<name>/
    SKILL.md        the agent-facing prompt
    references/     detail the prompt points at, loaded on demand
    scripts/        anything the lane shells out to
```

Drop the whole `.claude/` tree into your project — Claude Code picks them up automatically.

## What this is NOT

- Not a CI replacement. Workers commit and push branches; your existing CI still runs.
- Not a free pass on review. Set `human_approves_merge: true` if you want a person to OK every merge.
- Not for unreviewed AC-free issues. Cards need acceptance criteria — Super QA grades against them.

## Licence

MIT. See [LICENSE](./LICENSE).

## Credits

Designed and maintained by Eric Tech. Skill structure originally inspired by [obra/superpowers](https://github.com/obra/superpowers).

Workers run on the [mattpocock/skills](https://github.com/mattpocock/skills) process stack —
`tdd`, `diagnosing-bugs`, `code-review`, `grilling`, `to-spec`, `ask-matt`. The full
mapping (including the three skills that stayed because Matt's pack has no equivalent)
is in [`skills/super-build/references/decision-policy.md`](./skills/super-build/references/decision-policy.md).
