# super-board — agent-facing notes

This repo ships four skills under `skills/`:

- `super-board` — orchestrator (you, when invoked via `/super-board run`)
- `super-build` — headless builder worker
- `super-qa` — headless QA worker
- `super-review` — headless reviewer worker

## The cardinal rule

**`super-board` is an autonomous trader. The interactive Claude session that invokes `/super-board run` is an *orchestrator*, NOT a worker.** Its only jobs are:

1. Verify preconditions (clean git, no orphan workers, GraphQL quota, etc.).
2. Dispatch per the config's `worker_backend`:
   - `"workflow"` (default) — stay in-session and run the wave loop in `skills/super-board/references/run-workflow.md`: plan a wave, claim assignees, launch the `super-board-wave` dynamic workflow, reconcile, repeat. Lane agents inside the workflow do all product work.
   - `"claude-p"` (legacy, explicit opt-in only) — spawn the headless runner `nohup scripts/super-board-run.sh <slug> &`, report PID + log path, exit. The runner refuses to start (exit 78) unless the config sets this value.
3. Report back to the user (dispatch confirmation, or one status line per wave).

The orchestrator MUST NOT:

- Build, test, review, or fix issues itself. All product work is delegated to `claude -p` workers.
- Patch the dispatcher script or skill files mid-run, even if it sees a problem. Capture the symptom and tell the user; wait for explicit approval.
- Wait for workers. They write their evidence back to the GitHub issue + PR. The orchestrator's user-facing output is the dispatch confirmation, not the run result.
- Hold context for multi-card progress. State lives on the GitHub Project board + the inflight lockfiles, not in the orchestrator's session.

If a problem surfaces during the run, the orchestrator's reply is: "I saw X. Want me to dig in or stop the runner?" — not "I went ahead and fixed it."

## Worker rules

Workers (`super-build`, `super-qa`, `super-review`) share the dispatcher's `gh` token bucket. They MUST:

- Source `scripts/super-board-gh-guard.sh` at worker start.
- Call `sb_gh_guard_check 200` before any burst of `gh` calls.
- Prefer local `git blame` / `git log` over `gh api graphql` for any sub-agent that doesn't need fresh state.
- Cap adversarial sub-agents at 50 gh calls each. If a sub-agent runs out, it returns `confidence: insufficient_data` rather than burning the shared quota.
- Append `gh-quota-on-exit: graphql=<n>/5000 rest=<n>/5000` to the PR handoff comment.

See `skills/super-board/references/rate-limit-etiquette.md` for the full discipline.

## Installation contract

This repo is consumed by dropping its `.claude/`-shaped tree into a target project. The release zip is laid out so:

```
.claude/
├── skills/super-board/...
├── skills/super-build/...
├── skills/super-qa/...
├── skills/super-review/...
├── workflows/super-board-wave.js
└── bin/super-board-run.sh
    bin/super-board-gh-guard.sh
    bin/super-board-wave-plan.sh
```

The orchestrator skill expects `scripts/super-board-run.sh` to exist on the project's path. The release zip places it at `.claude/bin/`; users who prefer can symlink to `scripts/`.
