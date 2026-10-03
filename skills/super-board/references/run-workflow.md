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
3. Worktree check: if legacy `.worktrees/issue-*` exists, halt for inspection/move
   as described in run.md. Scan only board worktrees under `.claude/worktrees/`;
   when their named branch is gone use `git worktree remove` without force. Preserve
   detached, dirty, locked, unregistered, and unrelated folders.
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
   **Usage guard** — `bash .claude/bin/super-board-usage.sh check --config <config-path>`
   (Claude 5-hour and weekly plan usage; threshold `usage_pause_pct`, default 95):
   - exit 0 → launch.
   - exit 10 (pause) → launch nothing new. A wave already running finishes —
     stopping it mid-lane loses work. Then release claims as usual, post the
     resume note (one line to the user and the run manifest:
     `⏸ paused at <window> <used>% — resets <local time>; remaining: <N> cards; resume: /super-board run <slug>`),
     remove the wave lock, and wait for the reset. If a wake tool is available
     (`ScheduleWakeup`, or a `/loop` re-entry), schedule
     `min(3600, resets_at - now + 60)` seconds and chain until the reset; on
     wake re-run the check — trust the reading, not the clock — and continue
     only on exit 0. No wake tool → stop with the note; the user resumes.
   - exit 3 (unknown) → launch, and say once per run why the guard is blind
     (its `reason`). Do not halt a run on a missing signal.

   The signal is the `rate_limits` block Claude Code pipes to the status line —
   the only scriptable source of plan usage (`/usage` is interactive; `ccusage`
   reports tokens and cost, not % of plan). It reaches the script only if the
   user's status-line command records it; add one line after it reads stdin:
   `printf '%s' "$input" | bash <repo>/.claude/bin/super-board-usage.sh record`.
   Pro/Max only (API-key sessions have no `rate_limits`); it refreshes on this
   session's own turns. Claude Code's built-in pause at 100% remains the
   backstop — the guard exists so a wave does not start that the limit would
   cut off mid-lane. The legacy `claude-p` dispatcher does not run this guard.
2. **Plan the wave** —
   `bash .claude/bin/super-board-wave-plan.sh --config <config-path>` →
   The planner returns `cards`, `sweep`, `resume`, `flag` and `stranded`. **Act on
   `sweep`, `resume`, `flag` and `stranded` BEFORE launching** (run.md → "The wave-start
   sweep"): move every swept card to `Ready` with a comment naming what cleared
   it, move every `resume` card (🙋 needs you, human said done) to `Review` and
   label its PR `needs-you:done`, comment on every flagged card asking for its
   `## Blocked by` line to be fixed, and return every stranded Building card to
   `Ready` (below). Swept, resumed and stranded cards are NOT in this pass's
   `cards`; they join the next wave.

   **Stranded Building cards.** A card in Building with no assignee between
   waves has no live worker — a stopped or crashed wave left it mid-build. For
   each: find its branch (`git ls-remote --heads origin 'issue-<N>-*'`) and any
   leftover `.claude/worktrees/issue-<N>-build/`. If its HEAD is detached, keep it:
   its commits may have no other ref. Otherwise remove it with `git worktree remove`
   without force. On detached HEAD or removal failure (dirty, locked, or unregistered),
   keep the folder and Building status, report the recovery path, and do not
   redispatch that card until its work is preserved. Otherwise keep the branch and PR,
   move the card to `Ready`, and comment:
   `[orchestrator] [report] ↩️ back to Ready · stranded in Building` / `Did: found no live
   worker` / `✅ Done: card moved to Ready · branch <name> kept` / `Next: builder`
   (writing-standard.md § 4). The next Builder continues on the branch.
   **Builder pre-flight.** No card goes Ready → Building unchecked. The wave's first phase
   (`Pre-flight` in `super-board-wave.js`, before `runLane('build')`) runs one cheap sub-agent per
   batch of up to 5 Ready cards: already merged? already in progress (open PR or another card)?
   same files as an open PR? unclear? It runs `super-board-preflight.sh`, posts the Block template
   and moves held/sequenced cards to Blocked itself (run.md → "Builder pre-flight"). The summary
   reports those as `preflight:blocked`; `preflight:failed` means pre-flight was blind and the card
   stays in Ready for the next wave. Sequenced cards carry a `blocked-by:` line, so this same sweep
   frees them when the overlapping PR's issue closes.
   Wave width is not `max_workers` any more — it is however many cards the
   dependency graph says are free. The runtime caps concurrency and queues the
   rest, so a 19-card wave is normal and not a misconfiguration.
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
   `args: { configPath, cards, humanApprovesMerge, tier }` (`cards` straight from the planner: each
   carries `lane` and `labels`, and a `qa` card skips the Builder). Runs in the background; the
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
6. **Report** — one short block to the user per wave, in the session. Outcome
   first, one line per card that needs a human, then what happens next:

   ```
   Wave 3 · 5 cards → 2 merged · 1 bounced · 1 blocked · 1 failed · usage 5h 62%
     🛡 #15 Blocked 🔐 missing STRIPE_TEST_KEY — owner: Eric
     ❌ #18 failed: build lane returned no result — retried next wave
   Next: wave 4 (3 cards)   |   ⏸ paused until 14:05   |   ✅ board drained
   ```
   Merged and bounced cards are counts, not lines — they need nobody. Every
   `human-gate`/`blocked` card gets its line and its owner: that is the
   human's queue. Never report a card as done that is not on the base branch.
7. **Halt gates** — stop with a report if: 3 consecutive waves made zero
   progress (every card bounced/failed); block-rate exceeds
   `block_rate_alert_pct` of initial Ready; or the user says stop. The halt
   note is four lines: `🛑 halted — <gate>` · the evidence (counts, the cards
   that kept bouncing) · what is left in flight or claimed · `Resume:
   /super-board run <slug>` and who must act first.
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
  Ready → Building) come back by themselves: the next run's crash-recovery
  sweep releases their claim and the planner reports them in `stranded`
  (wave loop step 2). No manual drag.

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
    "Bash(bash .claude/bin/super-board-preflight.sh:*)",
    "Bash(bash .claude/bin/super-board-usage.sh:*)",
    "Bash(bash .claude/bin/super-board-pr-body.sh:*)", "Bash(gh pr edit:*)",
    plus your project's test runners (e.g. "Bash(npm test:*)", "Bash(npx playwright:*)").

Merging is NOT in the base list. On a board whose `merge_policy.default` is
`"auto"`, `super-board onboard` offers the merge lines as a diff to approve
up front (onboard → Permissions), so the first overnight run does not stall:

    "Bash(bash .claude/bin/super-board-merge-gate.sh:*)", "Bash(gh pr merge:*)",
    plus one line per configured migrate command in `migrations.commands`
    for the envs in `migrations.allowed_envs`.

Without them every Reviewer merge pauses for one interactive approval, so the
backend is **attended-only**. With them, the gate still enforces
`merge_policy` (money / auth / destructive schema / over `auto_max_lines` → human, exit 7) and `migrations`
(live DB → 🙋 needs you, exit 8), so the allowlist removes the prompt, not
the policy. Pair auto-merge with a non-production `base_branch`.

> **Read this before starting an overnight wave (issue #9).** The two settings
> interact, and the failure is silent. A board configured
> `"human_approves_merge": false` but run **without** `"Bash(gh pr merge:*)"`
> allowed will build, test and review cards all night and land **nothing** —
> each Reviewer stalls on an approval prompt nobody is there to click, and the
> card returns to Review to be re-reviewed on the next wave.
>
> Pick one deliberately:
>
> | Intent | `human_approves_merge` | Allowlist `gh pr merge` | Reviewer's terminal state |
> | --- | --- | --- | --- |
> | Attended — you click each merge | `false` | no | pauses on a prompt |
> | Unattended auto-merge | `false` | **yes** | card → Done, merge confirmed (money/auth/schema, live migrations → 🙋 Blocked for you) |
> | Human merges later, agent never does | `true` (or `merge_policy.default: "human"`) | no | card stays in Review |
>
> Row 2 is the only combination that lands code with nobody watching, and it
> requires a non-production `base_branch` — the run script's production-merge
> guard refuses to start otherwise. Whichever row you pick, the Reviewer still
> owes the full merge protocol in `run.md` → "Merge protocol": mark the draft PR
> ready, merge, **verify the merge commit is an ancestor of the base branch**,
> and only then move the card to Done. A merge-blocked PR goes to Blocked, not
> back to Review.
