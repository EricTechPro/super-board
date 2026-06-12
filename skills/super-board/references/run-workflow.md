# super-board run — workflow backend contract

The DEFAULT backend (v1.6.0+): used when the active config sets
`"worker_backend": "workflow"` or omits the key. The legacy bash dispatcher
(`.claude/bin/super-board-run.sh`, see `run.md`) runs only on explicit
`"worker_backend": "claude-p"`; this file ONLY changes who dispatches
workers. Lane lifecycles, branch/PR model, comment cadence, Block
templates, halt gates, and done conditions are all inherited from `run.md`
unchanged.

## Orchestrator delegation contract (NON-NEGOTIABLE, adapted)

The interactive session that runs this backend is the orchestrator. It:
- polls the board, claims assignees, launches workflow waves, reconciles
  results, posts notifications, and reports to the user between waves;
- does NOT do product work, patch lane skills mid-run, or hold per-card
  build context. Lane agents inside the workflow do all product work.

## Preconditions (before the first wave)

Run the same preconditions as `run.md` §Preconditions, minus PID checks:
1. Config exists and validates against `config-schema.json`.
2. Production-merge guard: refuse `base_branch: main` + `human_approves_merge:
   false` when deploy markers exist (same rule as super-board-run.sh).
3. Stale-worktree scan: remove `.worktrees/*` whose branch is gone.
4. `node --check` passes on a wrapped copy of
   `.claude/workflows/super-board-wave.js` (catches a broken script before
   burning tokens):
   `{ echo '(async function(){'; sed 's/^export const meta/const meta/' .claude/workflows/super-board-wave.js; echo '})'; } | node --check --input-type=module`
5. Wave marker FIRST, then the legacy check (lock-before-look closes the
   TOCTOU window where both backends pass each other's checks at once):
   a. Atomically create `.claude/super-board/inflight/workflow-wave.lock`
      (mkdir -p the directory) containing the config slug and start time:
      `(set -C; printf 'SLUG=%s\nSTARTED=%s\n' <slug> "$(date -u +%FT%TZ)" > <lock>)`.
      If it already exists and `/workflows` shows no running
      super-board-wave, it is stale from a crashed run — replace it.
      Remove the lock when the run ends or stops. The legacy dispatcher
      refuses to start (and halts mid-run) while it exists.
   b. THEN verify no legacy run is active: BOTH
      `pgrep -f 'super-board-run.sh'` (the legacy dispatcher idles between
      dispatches with zero workers alive) and
      `pgrep -f 'claude -p .*super-board run'` are empty, AND `/workflows`
      shows no running super-board-wave. If a legacy run is detected,
      remove the lock just created and stop — the legacy run won.
6. Crash-recovery sweep (the workflow backend's equivalent of the legacy
   reaper): with no wave running, strip `bot_identity` from any
   Review/QA/Ready/Building card that still carries it
   (`gh issue edit <n> --remove-assignee <bot_identity>`). A crashed
   orchestrator releases nothing — leaked assignees make the planner skip
   those cards forever and the board silently stops draining.

## The wave loop

Repeat until a done condition or halt gate fires:

1. **Rate guard** — `gh api rate_limit`; if GraphQL remaining < 200, wait for
   reset (same thresholds as run.md).
2. **Plan the wave** —
   `bash .claude/bin/super-board-wave-plan.sh --config <config-path>` →
   `{cards: [...]}`. Selection is backlog-aware: one card per non-empty
   column downstream-first (Review → QA → Ready), then remaining
   `max_workers` slots fill from the most backlogged column; extra Review
   cards only when `human_approves_merge: true` (merge-race guard). If
   `cards` is empty and Building/QA/Review counts are 0 → done. If empty
   but cards sit in Blocked only → report and stop.
3. **Claim** — for each card, `gh issue edit <n> --add-assignee <bot_identity>`,
   then VERIFY: re-read assignees (`gh issue view <n> --json assignees`) and
   proceed only if the list is exactly `[<bot_identity>]`. Adding an assignee
   does NOT fail when someone else already claimed (issues accept up to 10
   assignees), so the add alone is not a mutex — on any other assignee set,
   remove own assignee and skip the card (race lost). Skipped when
   bot_identity is unset — accepted single-orchestrator risk: without it
   there is no cross-session claim at all, so never run two orchestrators
   (or /loop re-entries) against the same board without bot_identity.
4. **Launch** — Workflow tool with
   `scriptPath: .claude/workflows/super-board-wave.js` and
   `args: { configPath, variant, cards, humanApprovesMerge, tier }`. Runs in the background; the
   orchestrator stays responsive. `humanApprovesMerge` comes from the config; when false the workflow serializes Review-lane agents (merge-race guard, execution side).
   `tier` is the run's model ladder: `'low'` when the user invoked
   `super-board run --low` (haiku/sonnet/opus by card complexity), `'high'`
   for `run --high` (opus floor, session model above), omitted/`'medium'`
   otherwise (sonnet/opus/session — the default). A `model_tier` key in the
   config sets the default; an explicit flag wins over config.
5. **Reconcile** (when the run completes) — read the returned `cards`
   summary. For EVERY card in the wave, release the assignee
   (`gh issue edit <n> --remove-assignee <bot_identity>`, idempotent).
   Append one line per card to the run manifest
   `docs/super-board/runs/<date>-<slug>.md`:
   `| #N | <lanesRun> | <finalStatus> | <column> | <detail> |`.
6. **Report** — one short status line to the user per wave (and Telegram if
   notifications are enabled; currently disabled per CLAUDE.md). Surface any
   `human-gate`/`blocked` cards explicitly — these are the human's queue.
7. **Halt gates** — stop with a report if: 3 consecutive waves made zero
   progress (every card bounced/failed); block-rate exceeds
   `block_rate_alert_pct` of initial Ready; or the user says stop.
8. Loop to 1. For unattended cadence, the user may wrap this loop in /loop;
   the orchestrator must still stop at halt gates.

## Stop / resume

- Stop: `x` on the run in `/workflows` (or TaskStop), then release assignees
  for in-flight cards and post "stopped mid-flight" comments (same protocol
  as `references/stop.md`). Remove `.claude/super-board/inflight/workflow-wave.lock`.
- Resume: just run again — board state is the only state. A workflow stopped
  mid-wave can also be resumed in-session via `resumeFromRunId` (completed
  lane agents return cached results).
- Cards stranded in `Building` (wave stopped after the Builder moved
  Ready → Building): the wave planner only selects from Review/QA/Ready,
  so drag stranded Building cards back to Ready before re-running.

## Mid-run permission prompts

Lane agents inherit the session allowlist and run in acceptEdits. Add these
to your project's `.claude/settings.json` → `permissions.allow` so waves
don't stall on prompts:

    "Bash(gh issue view:*)", "Bash(gh issue edit:*)", "Bash(gh issue comment:*)",
    "Bash(gh pr view:*)", "Bash(gh pr diff:*)", "Bash(gh pr checks:*)", "Bash(gh pr comment:*)",
    "Bash(gh pr create:*)", "Bash(gh pr ready:*)", "Bash(gh project item-edit:*)",
    "Bash(gh project item-list:*)", "Bash(gh api:*)", "Bash(git worktree:*)",
    "Bash(git checkout:*)", "Bash(git add:*)", "Bash(git commit:*)",
    "Bash(git push:*)", "Bash(git pull:*)", "Bash(git fetch:*)", "Bash(git blame:*)",
    "Bash(mkdir:*)", "Bash(pgrep:*)", "Bash(node --check:*)",
    "Bash(bash .claude/bin/super-board-wave-plan.sh:*)",
    plus your project's test runners (e.g. "Bash(npm test:*)", "Bash(npx playwright:*)").

`gh pr merge` is deliberately NOT in the list — Reviewer merges remain
gated by an interactive prompt, and by `human_approves_merge` for boards
that require a human click. Consequence: on auto-merge boards
(`human_approves_merge: false`) every Reviewer squash-merge pauses for one
interactive approval, so this backend is **attended-only** by default.
For genuinely unattended auto-merge runs you must consciously add
`"Bash(gh pr merge:*)"` yourself — doing so removes the last human gate
before the base branch, so pair it with a non-production `base_branch`.
