# super-board run — workflow backend contract

Used when the active config has `"worker_backend": "workflow"`. The legacy
bash dispatcher (`scripts/super-board-run.sh`, see `run.md`) remains the
default backend; this file ONLY changes who dispatches workers. Lane
lifecycles, branch/PR model, comment cadence, Block templates, halt gates,
and done conditions are all inherited from `run.md` unchanged.

Requires dynamic workflows enabled in the host Claude Code session
(`/config` on Pro plans). Repo sources: `workflows/super-board-wave.js`
(installed at `.claude/workflows/`) and `scripts/super-board-wave-plan.sh`
(installed at `.claude/bin/`).

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
5. No legacy run active: BOTH `pgrep -f 'super-board-run.sh'` (the legacy
   dispatcher idles between dispatches with zero workers alive) and
   `pgrep -f 'claude -p .*super-board run'` are empty, AND `/workflows`
   shows no running super-board-wave.
6. Wave marker: create `.claude/super-board/inflight/workflow-wave.lock`
   (mkdir -p the directory) containing the config slug and start time;
   remove it when the run ends or stops. The legacy dispatcher refuses to
   start while it exists — this is the reverse half of precondition 5.

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
3. **Claim** — for each card, `gh issue edit <n> --add-assignee <bot_identity>`
   (skip the card on claim failure — race lost). Skipped when bot_identity
   is unset.
4. **Launch** — Workflow tool with
   `scriptPath: .claude/workflows/super-board-wave.js` and
   `args: { configPath, variant, cards, humanApprovesMerge }`. Runs in the background; the
   orchestrator stays responsive. `humanApprovesMerge` comes from the config; when false the workflow serializes Review-lane agents (merge-race guard, execution side).
5. **Reconcile** (when the run completes) — read the returned `cards`
   summary. For EVERY card in the wave, release the assignee
   (`gh issue edit <n> --remove-assignee <bot_identity>`, idempotent).
   Append one line per card to the run manifest
   `docs/super-board/runs/<date>-<slug>.md`:
   `| #N | <lanesRun> | <finalStatus> | <column> | <detail> |`.
6. **Report** — one short status line to the user per wave (plus any
   configured notification channel). Surface any `human-gate`/`blocked`
   cards explicitly — these are the human's queue.
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

Lane agents inherit the session allowlist and run in acceptEdits. Allowlist
the gh/git commands they need in the target project's `.claude/settings.json`
or the run stalls on prompts. Recommended set:

```
Bash(gh issue edit:*)      Bash(gh issue comment:*)   Bash(gh pr comment:*)
Bash(gh pr create:*)       Bash(gh pr ready:*)        Bash(gh project item-edit:*)
Bash(gh project item-list:*)                          Bash(git worktree:*)
Bash(git checkout:*)       Bash(git add:*)            Bash(git commit:*)
Bash(git push:*)           Bash(git pull:*)           Bash(git fetch:*)
Bash(git blame:*)          Bash(node --check:*)       Bash(mkdir:*)
Bash(pgrep:*)              Bash(bash .claude/bin/super-board-wave-plan.sh:*)
```

plus your project's test runners (e.g. `Bash(npm test:*)`,
`Bash(npx playwright:*)`). `gh pr merge` is deliberately NOT allowlisted —
Reviewer merges remain interactively gated, and gated by
`human_approves_merge` for boards that require a human click.
