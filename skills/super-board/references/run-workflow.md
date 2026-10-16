# super-board run — workflow backend contract

The DEFAULT backend (v1.6.0+): used when the active config sets
`"worker_backend": "workflow"` or omits the key. The legacy bash dispatcher
(`.claude/bin/super-board-run.sh`, see `run.md`) runs only on explicit
`"worker_backend": "claude-p"`; this file ONLY changes who dispatches
workers. Lane lifecycles, branch/PR model, comment cadence, Block
templates, halt gates, and done conditions are all inherited from `run.md`
unchanged.

## Codex runs

`/super-board run --codex` uses headless Codex for every lane of every wave,
overriding `worker_backend`. Use it when Claude's remaining usage is low or to try another model.
`--codex --low` / `--codex --high` pick the Codex ladder the same way the tier flags
pick Claude's (flag, else config `model_tier`, else medium); pass it as `--tier`.
A cheap router (`gpt-6-luna`) grades each Ready card low/medium/high, and the lane
launcher's `CODEX_LADDERS` table maps tier × grade to `-m <model>`; a card entering past
Ready takes its tier's medium cell. `--codex=<model>`, else optional `codex.model`,
pins one model for every card and skips the router.
Keep this run choice in each wave and resume command; skip only the Claude usage guard.

**Inside Codex, plain `run` is `--codex`.** Your tool list has no Workflow tool, or
`bash .claude/bin/super-board-host.sh` prints `codex` → run as `--codex` (tier flags and
`--codex=<model>` still apply); it counts as explicit `--codex`, Review included.
Say so once, in the first wave report: `🔁 codex host — running as --codex`. Never improvise a Claude workflow wave in Codex.

After the same plan and claim steps, launch this command as a background task:
`bash .claude/bin/super-board-codex-wave.sh --config <config-path> --cards <claimed-cards.json> --codex[=<model>] --tier <low|medium|high> --output <wave-result.json>`.
The helper starts one `super-board-codex-lane.sh` per card/lane, cards in parallel,
each advancing Build → QA → Review only after a successful handoff (QA labels skip Build).
Concurrency uses positive `max_workers`, otherwise `max(1, min(16, cpus - 2))`.
Pre-flight/classification and truth-check run inline; there are no Claude sub-agents.
Each lane emits `{status,column,detail}`; the wave returns the same `cards` summary
as the workflow, so reconcile, manifest, board/comments and throttle steps stay the same.
Review is allowed only with explicit `--codex`; merges still use the unchanged
merge gate with `--expect-head <reviewed-SHA>` and verify landing per `run.md`.
Concurrent reviews share that gate's merge mutex. Network and repo/git-dir writes
use the lane launcher's sandbox settings, including an external submodule git dir.

## Required GitHub evidence and a paused run

Required reads use `.claude/bin/super-board-github-read.py --kind <shape> -- <gh args>`.
Three total attempts means the first attempt plus two retries of that same read;
unrelated successful calls do not reset its failures. Invalid GraphQL queries,
authentication, and permission errors stop immediately. Do not retry mutations.
A payload that misses an agent-facing `--kind` shape (`READ_SHAPES` in
`workflows/super-board-wave.js`) exits 64 for that call only, printing the valid
form; it never halts the run. Fixed-command scripts set `SB_GITHUB_READ_STRICT=1`.

Exit **79**, a workflow result with `halted: true`, or a failed `--check` ends this
run. Check the helper's `--check` before claims, board/comment writes, each new
lane/wave, and all migration/merge steps. The marker is shared through the main
checkout's `.claude/super-board/github-halt.json`, including linked worktrees.
Cancel active workflow agents using local workflow controls (Codex: stop the background wave task); do not launch more
lanes. Already-running agents stop at their next checkpoint; this is not an
instantaneous process-wide kill. Preserve worktrees, claims, card statuses, and
approval evidence. Do not move cards to Done/Blocked or release claims using an
unavailable GitHub API. Report the local saved reason and what remains in flight.

After fixing access or the invalid query, explicitly resume with the helper's
`--resume`. It rechecks the failed read before clearing the marker and archives
the original reason. Failed recovery leaves the pause intact. When the caller's
query was corrected or PR metadata changed, supply its current read explicitly:
`--resume --kind <same-shape> [--meta <fresh-meta.json>] -- <corrected gh read args>`.
The replacement must pass the same evidence validator; the broken saved query
is retained in the archived record. This is a read-only recovery check. An uncertain write
has no automatic recovery probe: inspect the remote outcome first, then archive
the halt record explicitly; never rerun a migration/write as a health check. Then follow normal
run preflight/reconcile, inspect preserved worktrees, and start a fresh wave.
Do not schedule automatic retries of the stopped run.

## Orchestrator delegation contract (NON-NEGOTIABLE, adapted)

The interactive session that runs this backend is the orchestrator. It:
- polls the board, claims assignees, launches workflow waves, reconciles
  results, posts notifications, and reports to the user between waves;
- does NOT do product work, patch lane skills mid-run, or hold per-card
  build context. Workflow lane agents or explicitly selected Codex workers do all product work.

## Preconditions (before the first wave)

Run the same preconditions as `run.md` §Preconditions, minus PID checks:
1. Config exists and validates against `config-schema.json`. Run
   `python3 .claude/bin/super-board-verification-ready.py --config <config>`; exit 9
   stops before dispatch until the owning project's verification commands are configured.
   Preserve work; repair setup and restart explicitly, never bounce to Build.
2. Production-merge guard: refuse `base_branch: main` + `human_approves_merge:
   false` when deploy markers exist (same rule as super-board-run.sh).
3. Worktree check: if legacy `.worktrees/issue-*` exists, halt for inspection/move
   as described in run.md. Scan only board worktrees under `.claude/worktrees/`;
   when their named branch is gone use `git worktree remove` without force. Preserve
   detached, dirty, locked, unregistered, and unrelated folders.
4. For Claude waves, `node --check` passes on a wrapped copy of
   `.claude/workflows/super-board-wave.js` (catches a broken script before
   burning tokens):
   `{ echo '(async function(){'; sed 's/^export const meta/const meta/' .claude/workflows/super-board-wave.js; echo '})'; } | node --check --input-type=module`
   With `--codex`, instead require `codex` on PATH and `bash -n` on both Codex launcher scripts.
5. Wave marker FIRST, then the legacy check (lock-before-look closes the
   TOCTOU window where both backends pass each other's checks at once):
   a. Atomically create `.claude/super-board/inflight/workflow-wave.lock`
      (mkdir -p the directory) containing the config slug and start time:
      `(set -C; printf 'SLUG=%s\nSTARTED=%s\n' <slug> "$(date -u +%FT%TZ)" > <lock>)`.
      Before replacing an existing marker, check `/workflows` and verify the PID
      in `.claude/super-board/codex-wave.pid` (plain numeric PID) with `kill -0` plus its process command.
      Only if neither backend has an active wave and no repo-local Codex lane
      remains is the marker stale from a crashed run — replace it.
      Remove the lock when the run ends or stops. The legacy dispatcher
      refuses to start (and halts mid-run) while it exists.
   b. THEN verify no legacy run is active: BOTH
      `pgrep -f 'super-board-run.sh'` (the legacy dispatcher idles between
      dispatches with zero workers alive) and
      `pgrep -f 'claude -p .*super-board run'` are empty, AND `/workflows`
      shows no running super-board-wave, AND no `super-board-codex-wave.sh` or
      `super-board-codex-lane.sh` process belongs to this repo. If a legacy run is detected,
      remove the lock just created and stop — the legacy run won.
6. Crash-recovery sweep (the workflow backend's equivalent of the legacy
   reaper): with no wave running, strip `bot_identity` from any
   Review/QA/Ready/Building card that still carries it
   (`gh issue edit <n> --remove-assignee <bot_identity>`). A crashed
   orchestrator releases nothing — leaked assignees make the planner skip
   those cards forever and the board silently stops draining.
7. Database reach: for every env in `migrations.allowed_envs` with a command, run its read-only
   `migrations.checks[env]` (e.g. `supabase migration list --db-url …`). A failure halts the run
   with the check's error — a broken URL caught here costs nothing; caught at merge time it
   strands a wave of reviewed PRs. An env with a command and no check: say so once, then go on.
   The URL resolves from the project's `.env`, never the session (config-schema → `migrations`).

## The wave loop

Repeat until a done condition or halt gate fires:

1. **Rate guard** — `sb_gh_guard_check 200` (super-board-gh-guard.sh; `gh api rate_limit` misreports GraphQL); if GraphQL remaining < 200, wait for
   reset (same thresholds as run.md). A failing `gh` call outranks the reading:
   right after a reset the REST reading has shown 4999 while calls still failed.
   With GraphQL dry, the orchestrator's own writes go over REST, a separate
   quota: `gh api repos/<o>/<r>/issues/<n>/comments -f body=…` for a comment,
   `gh api -X DELETE repos/<o>/<r>/issues/<n>/assignees -f 'assignees[]=<bot>'`
   to release a claim. Board moves have no REST route; they wait for the reset.
   **Usage guard** (Claude waves only; skip for `--codex`, explicit or host-switched) — `bash .claude/bin/super-board-usage.sh check --config <config-path>`
   (Claude 5-hour and weekly plan usage; threshold `usage_pause_pct`, default 95):
   - exit 0 → launch.
   - exit 10 with `usage_fallback: "codex"` → resolve the selected remaining
     chain for `--host codex` before fallback claims; missing helpers halt with
     `skills-readiness:` and preserve state. Build/QA may use
     `super-board-codex-lane.sh` WITHOUT `--codex`; Review remains refused.
     Fallback never grants merge ownership; use explicit `run --codex` for all lanes.
     Plan as usual, take the `build` and `qa` cards (`review` cards wait), and for ONE
     card at a time claim it, run `bash .claude/bin/super-board-codex-lane.sh --config
     <config-path> --card '<card JSON>' --lane <build|qa>`, read its JSON exit like a lane
     result, then reconcile (step 5). Re-run the usage check between cards; on exit 0
     return to normal waves. The report line says `🔁 codex fallback`. Without
     `usage_fallback: "codex"` the launcher refuses (exit 78) unless `--codex` is given.
   - exit 10 otherwise (pause) → launch nothing new. A wave already running finishes —
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
   Exit 9 is a verification-readiness halt: preserve work and claims, repair the
   owning project's `verify_commands`, then restart explicitly. No GitHub recovery probe,
   rebase, Build bounce, or automatic retry.
   **Skill readiness before any wave writes.** Hydrate every selected issue body
   read-only with `.claude/bin/super-board-github-read.py --kind issue -- issue
   view <N> --json number,title,body`. Keep number, status, labels and literal body
   in a JSON array file. Run `python3 .claude/bin/super-board-skills-ready.py
   --root <repo-root> --host <claude|codex> --cards <cards.json>` for the actual
   worker host before sweep/resume/refresh/flag/stranded actions or Claim.
   Exit 10 names missing helpers: halt, preserve all state, repair the exact
   visible skill files and restart explicitly. Exit 64 means invalid input.
   GitHub hydration failure follows the existing exit-79 read policy.
   Empty selection checks no unused helpers. Repeat with the new host before
   usage fallback; Claude availability never proves Codex availability.
   Pass hydrated bodies into the wave. Workers recheck their lane before writes
   and activate conditional helpers only after `--require <exact-name>` passes.
   Untyped Ready cards conservatively check bug and feature chains before
   classification. Existing docs/ux/tests/refactor rows keep their chain; check
   any proposed new label chain before writing that label.

   The planner returns `cards`, `sweep`, `resume`, `refreshApproval`, `flag` and `stranded`. **Act on
   `sweep`, `resume`, `refreshApproval`, `flag` and `stranded` BEFORE launching** (run.md → "The wave-start
   sweep"): move every swept card to `Ready` with a comment naming what cleared
   it, move every `resume` card (verified human approval of the current pinned
   request) to `Review`; `needs-you:done` is display-only. Move `refreshApproval`
   cards to `Review` solely to review the changed head and post a fresh human request;
   clear their stale `needs-you:done` display labels. They have no approval to merge.
   Comment on flagged cards asking for their
   `## Blocked by` line to be fixed, and return every stranded Building card to
   `Ready` (below). Swept, resumed, approval-refresh and stranded cards are NOT in this pass's
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
   Wave width is every card the dependency graph says is free, in flight
   first (Review → QA → Ready), cut to `max_workers` when it is set (0 or
   absent = no cap). `max_workers` is the GitHub-limit valve: step 5 lowers it
   after a wave that hit the hourly limit. If `cards` is empty and
   Building/QA/Review counts are 0 → done. If empty but cards sit in Blocked
   only → report and stop. This is unfinished work, not a completed-run calibration trigger.
3. **Claim** — for each card, `gh issue edit <n> --add-assignee <bot_identity>`,
   then VERIFY: re-read assignees (`gh issue view <n> --json assignees`) and
   proceed only if the list is exactly `[<bot_identity>]`. Adding an assignee
   does NOT fail when someone else already claimed (issues accept up to 10
   assignees), so the add alone is not a mutex — on any other assignee set,
   remove own assignee and skip the card (race lost). Skipped when
   bot_identity is unset — accepted single-orchestrator risk: without it
   there is no cross-session claim at all, so never run two orchestrators
   (or /loop re-entries) against the same board without bot_identity.
4. **Launch** — With `--codex`, or no Workflow tool, or the host check printing `codex`, use
   "Codex runs" above; otherwise Workflow tool with
   `scriptPath: .claude/workflows/super-board-wave.js` and
   `args: { configPath, cards, humanApprovesMerge, tier, forge }` (`cards` hydrated after the planner: each
   carries `lane` and `labels`, and a `qa` card skips the Builder; `forge` is the config's
   `forge` value — `"gitea"` switches every lane prompt to the tea read shapes, gitea.md).
   Runs in the background; the
   orchestrator stays responsive. `humanApprovesMerge` comes from the config; when false the workflow serializes Review-lane agents (merge-race guard, execution side).
   `tier` is the run's model ladder: `'low'` when the user invoked
   `super-board run --low` (haiku/sonnet/opus by card complexity), `'high'`
   for `run --high` (opus for every card), omitted/`'medium'`
   otherwise (sonnet/opus/session — the default). A `model_tier` key in the
   config sets the default; an explicit flag wins over config.
5. **Reconcile** (when the run completes) — read the returned `cards`
   summary. If `halted: true`, any card is `halted`, or the GitHub helper's `--check`
   fails, preserve claims and stop. For verification-readiness (exit 9), repair
   `verify_commands` and restart explicitly; do not invoke GitHub evidence recovery.
   For a GitHub read halt, follow "Required GitHub evidence" above. Otherwise,
   for EVERY card in the wave, release the assignee
   (`gh issue edit <n> --remove-assignee <bot_identity>`, idempotent).
   Append one line per card to the run manifest
   `docs/super-board/runs/<date>-<slug>.md`:
   `| #N | <lanesRun> | <finalStatus> | <column> | <detail> |`.
   Then the GitHub-limit step-down: save the returned `cards` to a temp file and run
   `bash .claude/bin/super-board-throttle.sh --config <config-path> --results <file>`.
   `hit: true` (GraphQL at 0, or a lane failed on the limit) has already written
   `max_workers` one lower into the config — unlimited → 3 → 2 → 1, floor 1 — so the
   next wave and the next run start narrower. Raising it again is the owner's call.
6. **Report** — one short block to the user per wave, in the session. Outcome
   first, one line per card that needs a human, then what happens next:

   ```
   Wave 3 · 5 cards → 2 merged · 1 bounced · 1 blocked · 1 failed · usage 5h 62%
     🛡 #15 Blocked 🔐 missing STRIPE_TEST_KEY — owner: Eric
     ❌ #18 failed: build lane returned no result — retried next wave
   Next: wave 4 (3 cards)   |   ⏸ paused until 14:05   |   ✅ board drained
   ```
   A throttle hit adds one line: `🐢 GitHub hourly limit hit — max_workers 3 → 2 (config saved)`.
   Merged and bounced cards are counts, not lines — they need nobody. Every
   `human-gate`/`blocked` card gets its line and its owner: that is the
   human's queue. Never report a card as done that is not on the base branch.
7. **Halt gates** — stop with a report if: 3 consecutive waves made zero
   progress (every card bounced/failed); block-rate exceeds
   `block_rate_alert_pct` of initial Ready; or the user says stop. The halt
   note is four lines: `🛑 halted — <gate>` · the evidence (counts, the cards
   that kept bouncing) · what is left in flight or claimed · `Resume:
   /super-board run <slug> [--codex[=<model>]] [--low|--high]` (retain the run's choice) and who must act first.
8. Loop to 1. For unattended cadence, the user may wrap this loop in /loop;
   the orchestrator must still stop at halt gates.

After normal completion, confirm all selected waves and lane tasks have ended,
finish final reconciliation, and release only the `workflow-wave.lock` created
by this host for this run (match its saved slug/start identity). Never remove
a marker owned by another or uncertain run; preserve it and skip calibration.
The read-only adapter never removes markers. Then run the optional adapter in [`calibration.md`](calibration.md).
This is a separate post-run task, after all lane workers and pending selected work
are accounted for. Do not calibrate per wave, on a halt/partial delivery, or from
Done counts or process exit alone. When enabled and eligible, delegate the installed
skill automatically using the helper's scoped brief; check its actual diff before
accepting automatic edits. An unavailable skill/host or an ineligible receipt is
reported as skipped and does not change the completed product work.

## Stop / resume

- Stop: `x` on the run in `/workflows` (or TaskStop), then release assignees
  for in-flight cards and post "stopped mid-flight" comments (same protocol
  as `references/stop.md`). Remove `.claude/super-board/inflight/workflow-wave.lock`.
- Codex stop: with GitHub available, run `bash .claude/bin/super-board-stop.sh <slug>`; it validates the wave PID and allows SIGTERM to cancel child lanes before releasing claims. Apply the same claim/comment/lock protocol to ALL selected claimed cards, including queued cards. During a GitHub halt, send SIGTERM only to the verified wave PID, wait for child cancellation, and preserve claims without GitHub writes.
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
don't stall on prompts (on a Gitea board the `gh …` lines are replaced by one
`"Bash(tea:*)"` — every forge call goes through the tea CLI; the script lines
are forge-neutral and stay — gitea.md):

    "Bash(gh issue view:*)", "Bash(gh issue edit:*)", "Bash(gh issue comment:*)",
    "Bash(gh pr view:*)", "Bash(gh pr diff:*)", "Bash(gh pr checks:*)", "Bash(gh pr comment:*)",
    "Bash(gh pr create:*)", "Bash(gh pr ready:*)", "Bash(gh project item-edit:*)",
    "Bash(gh project item-list:*)", "Bash(gh api:*)", "Bash(git worktree:*)",
    "Bash(.claude/bin/super-board-card.sh:*)",
    "Bash(git checkout:*)", "Bash(git add:*)", "Bash(git commit:*)",
    "Bash(git push:*)", "Bash(git pull:*)", "Bash(git fetch:*)", "Bash(git blame:*)",
    "Bash(mkdir:*)", "Bash(pgrep:*)", "Bash(node --check:*)",
    "Bash(bash .claude/bin/super-board-wave-plan.sh:*)",
    "Bash(bash .claude/bin/super-board-preflight.sh:*)",
    "Bash(python3 .claude/bin/super-board-skills-ready.py:*)",
    "Bash(bash .claude/bin/super-board-usage.sh:*)",
    "Bash(bash .claude/bin/super-board-throttle.sh:*)",
    "Bash(bash .claude/bin/super-board-codex-lane.sh:*)",
    "Bash(bash .claude/bin/super-board-codex-wave.sh:*)",
    "Bash(bash .claude/bin/super-board-host.sh:*)",
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
> `"human_approves_merge": false` and `merge_policy.default: "auto"`, processing
> otherwise ungated PRs **without** `"Bash(gh pr merge:*)"` allowed, will build,
> test and review cards all night and land **nothing** —
> each Reviewer stalls on an approval prompt nobody is there to click, and the
> card returns to Review to be re-reviewed on the next wave.
>
> Pick one deliberately:
>
> | Intent | Configuration | Allowlist `gh pr merge` | Reviewer's terminal state |
> | --- | --- | --- | --- |
> | Attended — approve each merge command | `human_approves_merge: false`, `merge_policy.default: "auto"` | no | pauses on a tool permission prompt |
> | Unattended auto-merge | `human_approves_merge: false`, `merge_policy.default: "auto"` | **yes** | card → Done after confirmed merge; configured human gates → 🙋 Blocked |
> | Every PR requires human approval through the gate | `human_approves_merge: false`, `merge_policy.default: "human"` | needed only if the agent will merge after approval | gate exits 7 → 🙋 Blocked until a human merges or approves the pinned request |
> | Legacy human-only switch | `human_approves_merge: true` | no | Reviewer stops before the gate; card stays in Review |
>
> Gate-based rows also need the merge-gate command allowed. A tool permission prompt
> is separate from the gate's human-approval request; allowing a command does not
> bypass `merge_policy`.
>
> Row 2 is the only combination that lands code with nobody watching, and it
> requires a non-production `base_branch` — the run script's production-merge
> guard refuses to start otherwise. Whichever row you pick, the Reviewer still
> owes the full merge protocol in `run.md` → "Merge protocol": mark the draft PR
> ready, merge, **verify the merge commit is an ancestor of the base branch**,
> and only then move the card to Done. A merge-blocked PR goes to Blocked, not
> back to Review.

### Skill-readiness reconciliation

Exit 10 from a skill check or lane result with detail `skills-readiness:` is a
readiness halt. Stop new dispatch, stop only this runner's active workers,
and preserve claims, inflight records, worktrees, card state and approval
evidence. Repair the exact host-visible skills and restart explicitly. Do not
release claims, bounce a card or enter a retry loop on this halt. Existing
preselection crash recovery remains the discovery step; once missing skills
are known, recovery and wave writes stop.
