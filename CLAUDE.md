# super-board — agent-facing notes

This repo ships eight skills under `skills/`: five you type (`super-board`, `super-collect`,
`ui-refine-loop`, `visual`, `git-sync`) and three the board runs (the lane workers `super-build`, `super-qa`,
`super-review`). Architecture findings come from `/super-collect architecture`.
Worktree cleanup (`hooks/cleanup-wt.py`) is a hook, not a skill. README skill tables are generated
by `scripts/super-board-readme-sync.py` from SKILL.md frontmatter and `skills/families.json`.
A board runs on **GitHub (default) or Gitea** — the config's `forge` key decides; every forge
rule, mapping and degradation lives in `skills/super-board/references/gitea.md`. Forge dispatch
code: `scripts/super-board-forge.{py,sh}` + `super-board-gitea-{read.py,api.sh}`.

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
- Wait on individual workers or relay their work. They write their evidence back to the forge issue + PR (GitHub or Gitea). The orchestrator's user-facing output is the dispatch confirmation (claude-p) or one short report per wave (workflow), not the run result.
- Hold context for multi-card progress. State lives on the board (GitHub Project / Gitea project) + the inflight lockfiles, not in the orchestrator's session.

If a problem surfaces during the run, the orchestrator's reply is: "I saw X. Want me to dig in or stop the runner?" — not "I went ahead and fixed it."

## Worker rules

Workers (`super-build`, `super-qa`, `super-review`) share the dispatcher's forge token bucket
(the `gh` GraphQL+REST budget, or the Gitea instance's API limits — often disabled, in which
case the per-worker call budget is the only guard). They MUST:

- Required reads use the forge's wrapper — `.claude/bin/super-board-github-read.py`, or
  `.claude/bin/super-board-gitea-read.py` on gitea boards; exit 79 stops the run.
- Check its `--check` before forge writes, migrations, merges, and new dispatch; preserve work when halted.
- Source `.claude/bin/super-board-gh-guard.sh` (`scripts/` in this repo) at worker start — it is forge-aware.
- Call `sb_gh_guard_check 200` before any burst of forge calls.
- Prefer local `git blame` / `git log` over forge API calls for any sub-agent that doesn't need fresh state.
- Cap adversarial sub-agents at 50 forge calls each. If a sub-agent runs out, it returns `confidence: insufficient_data` rather than burning the shared quota.
- Append `gh-quota-on-exit: graphql=<n>/5000 rest=<n>/5000` (GitHub) or
  `gh-quota-on-exit: budget=<n> rate_limits=off|<rem>/<limit>` (Gitea) to the PR handoff comment.

See `skills/super-board/references/rate-limit-etiquette.md` for the full discipline.

## Installation contract

`install.sh [--no-hooks] [--protect-main] <target>` copies the pack into the target project's `.claude/` tree:

```
.claude/
├── skills/<all eight>/...
├── hooks/guard-*.py, cleanup-wt.py   (wired into settings.json; --no-hooks skips)
├── workflows/super-board-wave.js, ui-refine-loop.js
└── bin/super-board-*.sh (incl. pr-body, forge, gitea-api), super-board-*.py (status, merge-policy, agents-md, settings, setup, forge, gitea-read), super-qa-file-bug.sh, super-review-file-refactor.sh
```

It also refreshes the managed `<!-- super-board:begin … -->` block in the target's AGENTS.md when
one exists (nothing outside the markers), records an older install in
`.claude/super-board/upgrade.json`, prints grouped emoji output, and asks nothing:
`super-board onboard` asks the questions. Onboard's 🔍 Checks (`scripts/super-board-setup.py`)
fixes must-haves and finishes upgrades with no question.

## Board shape (v3.0.0)

Columns are always Backlog · Ready · Building · QA · Review · Blocked · Done — no Skipped, no
per-board `variant`. Labels `qa` · `bug` · `feature` route cards: `qa` skips Building, everything
else (and no label) is built. Change routing in `scripts/super-board-wave-plan.sh`,
`workflows/super-board-wave.js` and `run.md` → "Lanes and label routing" together.
On Gitea the seven columns are repo-project columns (`project.number` = the project's API id);
`super-board-card.sh` normalizes both forges into one `{items,totalCount}` shape.

Skills call the dispatcher scripts as `.claude/bin/<script>`.

## Writing

Commits, PR bodies, tickets and comments in this repo follow
`skills/super-board/references/writing-standard.md`, the same standard super-board writes into
every project it is installed in.

| Thing | Format |
|---|---|
| Commit | `<emoji> [type] scope: subject` + short bullets (✨ feat · 🐛 fix · 🔧 chore · ♻️ refactor · 🧪 test · ⚡ perf · 📝 docs · 👷 ci · 💄 ui · 🔒 security · ⏪ revert · 🚧 wip) |
| PR body | marker blocks, one owner each: status · problem · solution · ac · history · visual · risk |
| Ticket | Problem · Context · Fix · Acceptance Criteria · Risk · Blocked by (+ Evidence for bugs) |
| Comment | `[role] [label] status` · Did · ✅ Done · ❌ Not done · Next · ≤ 8 lines |
| PR author notes | Purpose · What changed · Why it matters, in native file/inline review comments; follow `skills/super-board/references/pr-author-notes.md` |

- NEVER rewrite a whole PR body: `scripts/super-board-pr-body.sh` rewrites one block.
- ALWAYS change a format in `writing-standard.md` first, then the templates and `tests/test_writing_format.py`.

## Release checks

Run `bash tests/run-safety.sh` for the offline suite. A pushed `v*` tag runs the same checks
on Linux/macOS plus status-reader smoke checks, then publishes only if they pass. Follow
[RELEASING.md](RELEASING.md); it also lists the settings needed to limit manual bypass.

## Map pages (diagrams/)

Every map page must be listed in the nav and in Explore, from the registry `diagrams/_shared/maps.json`. To add one: create `diagrams/<map>/map.json` (or `map.py`), add its entry (title, blurb, path, thumb, logo) to the registry, add a 960x600 thumb, run `python3 diagrams/_shared/sync_explore.py` then `python3 diagrams/_shared/build_skillmap.py <map>`. The build and `sync_explore.py --check` fail if a map page has no registry entry or the Explore cards are stale.
