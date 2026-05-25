# super-board stop — full contract

Pointer: spec `docs/superpowers/specs/2026-05-21-super-board-design.md` §9 (added in v1.3.0).

**Where it runs:** interactive orchestrator. Spawns the headless `scripts/super-board-stop.sh` synchronously, reports the summary, exits. No background processes.

## What stop does — the one-line version

Tears down an in-flight `super-board run` cleanly: posts a "stopped here" comment on every claimed issue + PR, releases the assignee mutex, kills workers + dispatcher, removes lock files. **Run = resume**, so the next `super-board run` picks up where stop left off.

## Intro shown when stop runs

```
🛑 super-board stop
─────────────────────────────────────────────────────────
Purpose: terminate the in-flight run and wrap up context
         so the next `super-board run` resumes cleanly.

Progress: ✅ onboard  →  ✅ run  →  🛑 stop (you are here)
─────────────────────────────────────────────────────────
```

## Preconditions

| Check | Action on fail |
|---|---|
| Active config exists (arg or `.claude/super-board/active`) | Exit 64: usage hint |
| Config file readable | Exit 66: "config not found" |
| `gh auth` valid | Continue anyway — comments may fail, kills still work |

Nothing else. Stop is intentionally tolerant — its job is to bring the system to rest, not to enforce policy.

## What stop reads

- `.claude/super-board/inflight/<issue-N>` — one file per in-flight worker. New (v1.3.0+) format: `PID=…\nLANE=…\nSTARTED=…`. Legacy single-line PID format is also supported.
- `pgrep -f 'super-board-run\.sh'` — dispatcher PID(s).
- `pgrep -f 'claude -p .*super-board'` — orphan worker scan (workers without a lock file, e.g. from a crashed dispatcher).

## Per-worker wrap-up (run for each in-flight lock)

1. **Look up branch + PR**
   - `git branch -a --list "*issue-<N>-*"` → latest commit on the issue branch.
   - `gh pr list --search "head:issue-<N>-*"` → PR number, if any.
2. **Post `🛑 stopped mid-flight` comment** on the issue AND (if it exists) the PR. The comment includes:
   - Lane, worker PID, UTC timestamp.
   - Last commit on the branch (the "resume point" — anything past it was unpushed and is lost).
   - Plain-English resume hint: `super-board run <slug>`.
3. **Release the assignee mutex** on the issue (`gh issue edit --remove-assignee <bot>`).
4. **Remove descriptive labels** (`loop:in-build`, `loop:in-qa`, `loop:in-review`) — best-effort.
5. **SIGTERM the worker PID**, sleep 1s, SIGKILL if still alive.

## After the per-worker loop

6. **Sweep orphan workers** — `pgrep -f 'claude -p .*super-board'` catches any `claude -p` worker that wasn't in `inflight/` (defensive against crashed dispatchers).
7. **Kill the dispatcher loop** — `pgrep -f 'super-board-run\.sh'`, SIGTERM → 1s → SIGKILL.
8. **Clear in-flight locks** — `rm -f .claude/super-board/inflight/*`. The PIDs they reference are dead now.
9. **Print summary** — workers stopped, dispatchers stopped, resume command.

## What stop does NOT do (deliberate)

- **Does not wait for workers to finish.** `claude -p` workers have no SIGTERM handler that flushes a partial commit. Any uncommitted edits in worker worktrees are discarded. The last pushed commit on the branch is the actual resume point.
- **Does not touch worktrees** under `.worktrees/`. Leaving them in place lets the next worker check out the same branch faster; the dispatcher's stale-worktree scan cleans up anything truly dead on next start.
- **Does not touch branches or PRs.** Both persist. State lives on the GitHub Project board — cards stay in whichever column they were in when stopped.
- **Does not modify the config.** A stopped run is not a deactivated config; `.claude/super-board/active` is preserved.
- **Does not bypass the GitHub assignee mutex.** It releases the mutex, then kills. If the GitHub API is unreachable, release is best-effort and the orphan-scan + reap-on-next-start covers the gap.

## Resume = run (no separate verb)

There is **no `super-board resume` verb on purpose**. The board is the state:

- Cards sit in whichever column they were in when stopped.
- Branches + PRs persist.
- The wrap-up comment on each in-flight issue documents what was in progress.
- `super-board run <slug>` claims the same cards on its next tick and re-runs the lane from scratch (Builder re-implements, Tester re-runs tests, Reviewer re-reviews — there's no per-lane checkpoint inside a worker).

Resume cost: **one lane cycle per previously-in-flight card** (Builder ~5min, Tester ~10min, Reviewer ~3min on a typical card). Last-pushed commit is the floor; anything past it was unpushed and is lost.

## When to use stop

- Need to step away and don't want workers consuming gh quota / Claude budget while idle.
- Discovered a bug in the dispatcher / a skill and need to fix it before more cards process.
- About to make a destructive board edit (column rename, project re-permission) that would break in-flight workers.
- Rate limits, billing alerts, or any cross-cutting "stop everything" signal.
- End of a work session — clean shutdown beats letting workers run unattended overnight.

## When NOT to use stop

- A single card is stuck → fix the card; the lane-zombie watchdog auto-recovers, and the rebuild-cap gate moves persistently-failing cards to Blocked.
- The dispatcher's `no progress for 3 ticks` halt already fired → already stopped cleanly.
- You're just curious about status → use `super-board status` (read-only, no side effects).

## Orchestrator behavior (when Claude is asked to "stop super-board")

Per the cardinal orchestrator/worker rule:

1. Verify `.claude/super-board/active` exists OR a slug was provided.
2. Run `scripts/super-board-stop.sh <slug>` synchronously (it's fast — seconds, not minutes).
3. Pass through the script's summary to the user.
4. **Do not** retry kills, do not chase down zombies the script missed, do not "while you're at it" clean up worktrees or branches. If the script reported failures, surface them and wait for explicit user direction.

## Failure modes + recovery

| Symptom | Cause | Recovery |
|---|---|---|
| `gh issue comment` fails | gh auth expired or network blip | Comments are best-effort. The kill + lock cleanup still happens. Manually note the stop in the issue later if needed. |
| Assignee release fails (gh 403) | rate limit or auth | The next `super-board run` startup runs `reap_finished_locks` which sweeps stale assignees idempotently. No manual action needed. |
| Worker PID survives SIGKILL | extremely rare (kernel-level stuck process) | `ps aux \| grep claude -p` to confirm, then escalate via OS tools. |
| Stop reports "nothing to stop" but `ps` shows live workers | dispatcher and workers were started by a different repo / different inflight dir | Run stop in the right repo OR `pkill -f 'super-board-run\.sh'` manually + `pkill -f 'claude -p .*super-board'`. |

## Lock file format (v1.3.0+)

```
PID=12345
LANE=qa
STARTED=2026-05-24T18:42:11Z
```

Sourced as bash (no shell injection — the dispatcher writes only its own PID + a hardcoded lane name + a `date -u` timestamp). Legacy single-line PID files are still accepted by both the dispatcher's `read_lock` helper and the stop script's same helper, so an upgrade mid-run is safe.
