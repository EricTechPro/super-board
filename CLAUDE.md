# super-board — agent-facing notes

This repo ships seven skills under `skills/`: the orchestrator `super-board`, the lane workers
`super-build`, `super-qa`, `super-review`, plus `super-collect` (primary), and `visual`,
`ui-refine-loop` (secondary). Architecture findings come from `/super-collect architecture`.
Worktree cleanup (`hooks/cleanup-wt.py`) is a hook, not a skill. README skill tables are generated
by `scripts/super-board-readme-sync.py` from SKILL.md frontmatter and `skills/families.json`.

## The cardinal rule

**`super-board` is an autonomous trader. The interactive Claude session that invokes `/super-board run` is an *orchestrator*, NOT a worker.** Its only jobs are:

1. Verify preconditions (clean git, no orphan workers, GraphQL quota, etc.).
2. Dispatch per the config's `worker_backend`:
   - `"workflow"` (default) — stay in-session and run the wave loop in `skills/super-board/references/run-workflow.md`: plan a wave, claim assignees, launch the `super-board-wave` dynamic workflow, reconcile, repeat. Lane agents inside the workflow do all product work.
   - `"claude-p"` (legacy, explicit opt-in only) — spawn the headless runner `nohup .claude/bin/super-board-run.sh <slug> &`, report PID + log path, exit. The runner refuses to start (exit 78) unless the config sets this value.
3. Report back to the user (dispatch confirmation, or one status line per wave).

The orchestrator MUST NOT:

- Build, test, review, or fix issues itself. All product work is delegated to workflow lane agents (or `claude -p` workers on the legacy backend).
- Patch the dispatcher script or skill files mid-run, even if it sees a problem. Capture the symptom and tell the user; wait for explicit approval.
- Wait on individual workers or relay their work. They write their evidence back to the GitHub issue + PR. The orchestrator's user-facing output is the dispatch confirmation (claude-p) or one short report per wave (workflow), not the run result.
- Hold context for multi-card progress. State lives on the GitHub Project board + the inflight lockfiles, not in the orchestrator's session.

If a problem surfaces during the run, the orchestrator's reply is: "I saw X. Want me to dig in or stop the runner?" — not "I went ahead and fixed it."

## Worker rules

Workers (`super-build`, `super-qa`, `super-review`) share the dispatcher's `gh` token bucket. They MUST:

- Source `.claude/bin/super-board-gh-guard.sh` (`scripts/` in this repo) at worker start.
- Call `sb_gh_guard_check 200` before any burst of `gh` calls.
- Prefer local `git blame` / `git log` over `gh api graphql` for any sub-agent that doesn't need fresh state.
- Cap adversarial sub-agents at 50 gh calls each. If a sub-agent runs out, it returns `confidence: insufficient_data` rather than burning the shared quota.
- Append `gh-quota-on-exit: graphql=<n>/5000 rest=<n>/5000` to the PR handoff comment.

See `skills/super-board/references/rate-limit-etiquette.md` for the full discipline.

## Installation contract

`install.sh [--no-hooks] [--protect-main] <target>` copies the pack into the target project's `.claude/` tree:

```
.claude/
├── skills/<all seven>/...
├── hooks/guard-*.py, cleanup-wt.py   (wired into settings.json; --no-hooks skips)
├── workflows/super-board-wave.js, ui-refine-loop.js
└── bin/super-board-*.sh, super-board-*.py (status, merge-policy, agents-md, settings), super-qa-file-bug.sh, super-review-file-refactor.sh
```

It also refreshes the managed `<!-- super-board:begin … -->` block in the target's AGENTS.md when
one exists (nothing outside the markers), and asks nothing: `super-board onboard` asks the questions.

Skills call the dispatcher scripts as `.claude/bin/<script>`.
