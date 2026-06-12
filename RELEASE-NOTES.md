# Release notes

## v1.6.0 — 2026-06-10

### Workflow backend is now the default; claude-p is explicit opt-in

`"worker_backend"` now defaults to `"workflow"` — `/super-board run <slug>` drains the board in-session via the `super-board-wave` dynamic workflow unless the config explicitly sets `"claude-p"`. The legacy dispatcher (`super-board-run.sh`) refuses to run (exit 78) for any config that doesn't opt in, so a stale habit or old script can't silently spawn headless `claude -p` workers.

### Hardened mutual exclusion, claims, and crash recovery (PR #3 review findings)

- **Reaper no longer eats the wave lock** — `reap_finished_locks()` skips non-numeric basenames in `inflight/`, so `workflow-wave.lock` survives coexistence instead of being deleted within one tick.
- **Per-tick mutex re-check** — the legacy dispatcher re-checks `workflow-wave.lock` every tick (exit 74), closing the TOCTOU window left by the startup-only check; the workflow side now locks first (atomic noclobber), then looks for a legacy run.
- **Claims are verified** — after `--add-assignee`, the orchestrator re-reads assignees and proceeds only if it's the sole assignee (adding never fails on a contested card, so the add alone is not a mutex).
- **Crash-recovery sweep** — on start, the workflow backend strips leaked bot assignees so a crashed orchestrator can't silently stop the board from draining.
- **Allowlist completeness** — added `gh issue view` / `gh pr view|diff|checks` (the classify and Reviewer prompts require them); documented that auto-merge boards are attended-only unless `gh pr merge` is consciously allowlisted.
- **Loud variant validation** — the wave planner exits 65 on an unknown `variant` instead of silently dropping the QA column.

## v1.5.0 — 2026-06-10

### Dynamic-workflow worker backend

New `worker_backend` config key selects how cards get worked: `"claude-p"` (default, unchanged — headless workers via `super-board-run.sh`) or `"workflow"` (opt-in — waves drained in-session via the `workflows/super-board-wave.js` dynamic workflow).

- **In-session waves** — `workflows/super-board-wave.js` runs a classify → build → qa → review pipeline per card. Lane lifecycles, branch/PR model, and Block templates are unchanged from `references/run.md`; only the dispatcher differs. See `skills/super-board/references/run-workflow.md`.
- **Backlog-aware wave selection** — `scripts/super-board-wave-plan.sh` picks one card per non-empty column downstream-first (Review → QA → Ready), then fills the remaining `max_workers` slots from the most backlogged column. Extra Review slots are unlocked only when `human_approves_merge: true`.
- **Review-lane mutex** — on auto-merge boards the workflow serializes Review-lane agents, so concurrent merges can't race.
- **Backend mutual exclusion** — the workflow backend writes `.claude/super-board/inflight/workflow-wave.lock`; the legacy dispatcher refuses to start while it exists (exit 74).
- **Tests** — 6-scenario suite at `tests/test-wave-plan.sh` pins the wave planner's selection logic against fixtures, no `gh` calls.

Why: replaces `nohup claude -p` dispatch ahead of the June 15 Agent SDK billing split. The legacy `claude-p` backend remains the default — nothing changes unless you opt in.

## v1.4.0 — 2026-05-27

### Pure-Python `super-board status` renderer (~50× faster)

The status snapshot now renders via `.claude/bin/super-board-status.py` instead of being assembled token-by-token by the model. Same locked 80-column kanban template; ~1.3s instead of ~1min per invocation.

Pure Python 3 stdlib + `gh` CLI. No bash, no jq. Works on macOS, Linux, and Windows.

Highlights:

- Handles both user-owned and organization-owned GitHub Projects (`repositoryOwner { ... on ProjectV2Owner }`).
- Paginates project items via cursor + endCursor, with a 2000-card ceiling and a truncation warning past that.
- Defensive input handling: slug-arg sanitization rejects `..` and other path-traversal sentinels; issue-title control-char strip prevents hostile titles from emitting escape sequences into the kanban frame.
- Lane-handoff fix: clean Build → QA → Review handoffs no longer leave phantom in-flight entries from the prior lane.
- Cross-platform CI (`.github/workflows/cross-platform.yml`): smoke matrix on ubuntu/macos/windows × py3.10/3.12, plus 22 parser fixture tests that pin the regexes against real dispatcher log lines.

Agents that invoke the `super-board` skill will now prefer the script and print its stdout verbatim. The locked template spec in `references/status.md` is retained as fallback / change-control documentation.

Contributed by @LucariusWest (#2).

## v1.3.0 — 2026-05-24

### New verb: `super-board stop`

Graceful shutdown of an in-flight run. One command, no manual `pkill` choreography, full context preserved on the board so the next `super-board run` resumes cleanly.

What it does, in order:

1. Inventories in-flight workers from `.claude/super-board/inflight/<issue-N>` lock files.
2. For each one, posts a `🛑 super-board · stopped mid-flight` comment on the issue **and** its PR, including lane, worker PID, UTC timestamp, last pushed commit (the "resume point"), and the literal resume command.
3. Releases the GitHub assignee mutex on each claimed issue + clears `loop:in-build`/`loop:in-qa`/`loop:in-review` descriptive labels.
4. SIGTERM → 1s → SIGKILL the worker PIDs.
5. Sweeps any untracked `claude -p .*super-board` orphan workers (defense against crashed-dispatcher leftovers).
6. Kills the dispatcher loop (`super-board-run.sh`).
7. Removes in-flight lock files. Leaves worktrees, branches, and PRs in place.

**Resume = run.** There is no separate `super-board resume` verb on purpose. The board is the state — cards sit in whichever column they were in when stopped, branches and PRs persist, and `super-board run <slug>` re-claims the same cards on its next tick. Each previously-in-flight card costs one extra lane cycle on resume.

What stop does NOT do (deliberate):

- Doesn't wait for workers to reach a clean stopping point — `claude -p` has no SIGTERM handler that flushes a partial commit. Any uncommitted edits in worker worktrees are discarded; the last **pushed** commit is the resume floor.
- Doesn't touch worktrees — the next worker re-checks-out the same branch faster.
- Doesn't touch branches or PRs.

### Lock file format upgrade (backwards-compatible)

The dispatcher now writes lock files as bash-assignment style:

```
PID=12345
LANE=qa
STARTED=2026-05-24T18:42:11Z
```

This lets `super-board stop` recover the lane name + dispatch time without an extra `gh` call. A new `read_lock` helper handles both v1.3.0+ and legacy single-line-PID formats, so an upgrade mid-run is safe — existing locks keep working until the dispatcher rewrites them on the next dispatch.

### Routing

`SKILL.md` now lists five verbs. `references/stop.md` is the full contract. New routing rows: `stop`, `pause`, `kill`, and `resume`/`pick up where I left off` (all route to `stop.md`, since resume is just `run` again).

## v1.2.0 — 2026-05-24

First public release.

### Worker-storm fixes (post-incident #381, originally landed in EricTechPro/BookKeepingApp 2026-05-22)

- **PID tracking + per-lane lockfile.** The dispatcher tracks `BUILD_PID`/`QA_PID`/`REVIEW_PID` and refuses to dispatch into a lane whose worker is still alive. Closes the 10–30s `claude -p` cold-start race that produced 7 racing workers on the very first run.
- **In-flight lockfiles** at `.claude/super-board/inflight/<issue-N>` containing the worker PID. `top_card_in_column` skips any issue with a live lock even before the assignee write propagates. Reaped each tick via PID liveness check.
- **Atomic assignee claim BEFORE worker spawn.** `try_claim_assignee` runs in the dispatcher and only proceeds to `nohup claude -p` if it wins the assignee write.
- **Orphan scan on startup.** Refuses to start if any `claude -p .*super-board run` worker is already alive from a prior crashed dispatcher run.

### Rate-limit fixes

- **Tick interval bumped 30s → 120s.** ProjectsV2 GraphQL query is ~103 points regardless of board size; 120s keeps usage at ~3.1k/hr, comfortably under the 5k/hr GraphQL budget.
- **Rate-limit guard** sleeps until reset when GraphQL remaining drops below 200.
- **Per-tick project-items cache** — one `gh project item-list` per tick, not per column lookup. ~7× quota cut.
- **Worker rate-limit etiquette** — sub-agent gh-call budgets, local `git blame` preference, `gh-quota-on-exit:` line required on every PR handoff comment.

### QA evidence

- **Mandatory inline screenshot embeds** on every QA exit (pass and fail) at standard viewports (1920×1080, 1024×768, 375×667). Screenshots committed to the issue branch BEFORE the GitHub comment is posted, so they render in-page.
- **`docs/super-board/runs/**/*.{png,jpg,webp,html,log,patch,diff,zip,trace}` gitignored** by default. Keep `.md` and `.json` summaries tracked for audit trail; drop the heavy artifacts. Users adopting on existing repos: `git rm --cached docs/super-board/runs/**/*.png` etc. to untrack what's already in.

### Documentation fixes

- **Card-locking semantics corrected.** The original spec said the GitHub assignee write was the lock. In practice it doesn't hold up — assigning yourself something you already have is a no-op on a solo account, and GH issues accept multiple assignees, so it never blocked a second worker. The real lock is the local `.claude/super-board/inflight/<N>` lockfile + per-lane PID tracking. Docs updated throughout.

### Other

- **Multi-attempt card-move guard.** Workers must call `sb_gh_guard_check` (or equivalent retry-with-backoff) around the column-move mutation and write a `move-mutation-result: ok|err|skipped` line in the PR handoff comment. Lets the dispatcher log retries and budget for them instead of silently re-dispatching every 10 min.
- **CI-budget bypass (💳).** If remote CI jobs `failed_to_start` due to Actions budget AND local-evidence is strong (truth gate passed, Tester clean, all threads clean), the Reviewer can squash-merge on local evidence with a `🛡 → ✅ CI-budget bypass` comment citing the failed run ID, Tester pass-count, and truth-gate score. Only for `💳` — never for `🛡` truth-fail, `🔐` missing creds, or `🧑` human-only decisions.
