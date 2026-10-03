# super-board

Drag a card into `Ready`, walk away, come back to a merged PR with evidence: **7 skills** — 5 primary, 2 secondary — 9 commands, 8 guards.

![Skills](https://img.shields.io/badge/skills-7-000000?style=flat-square)
![Version](https://img.shields.io/badge/version-2.6.0-000000?style=flat-square)
![Host](https://img.shields.io/badge/host-Claude%20Code-000000?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-000000?style=flat-square)

[![Watch the super-board walkthrough on YouTube](https://img.youtube.com/vi/nX_bGyIOFM4/maxresdefault.jpg)](https://youtu.be/nX_bGyIOFM4)

## Install

```bash
git clone https://github.com/EricTechPro/super-board /tmp/super-board   # or download a release zip
/tmp/super-board/install.sh /path/to/your-project                       # --no-hooks skips the guards; --protect-main adds the push guard
npx skills@latest add mattpocock/skills                                 # required: lanes call these by name
```

Then, inside Claude Code in your project: `/super-board onboard`, move cards to `Ready`, `/super-board run <slug>`.

## Skills

<!-- skills:start -->
**Primary — the board and its lanes**

| Skill | What it does |
|---|---|
| [`/super-board`](skills/super-board/README.md) | Orchestrator: plans waves, runs Build → QA → Review, merges when green. |
| [`/super-build`](skills/super-build/README.md) | Builder lane: worktree, smallest safe change, tests, draft PR. |
| [`/super-qa`](skills/super-qa/README.md) | Tester lane: evidence, test-gap check, screenshots, or bounce to Build. |
| [`/super-review`](skills/super-review/README.md) | Reviewer lane: own hypotheses, remembers prior findings, merge gate. |
| [`/super-collect`](skills/super-collect/README.md) | Finds problems (Sentry, PostHog, issues, PRs, architecture) and files verified Backlog cards. |

**Secondary — standalone helpers**

| Skill | What it does |
|---|---|
| [`/visual`](skills/visual/README.md) | One HTML page: branch recap, plan, or codebase map with diagrams. |
| [`/ui-refine-loop`](skills/ui-refine-loop/README.md) | Critique → refine loop that polishes one page or component. |
<!-- skills:end -->

Each name links to that skill's README. Lane skills run as agents inside the `super-board-wave` workflow.

## Commands

| | |
| --- | --- |
| `/super-board onboard` | One-time setup: checks the board's columns, writes `.claude/super-board/configs/<slug>.json` |
| `/super-board lint` | Flags vague ACs and unreadable `Blocked by` lines before agents spend tokens |
| `/super-board status` | Read-only board snapshot, column counts, in-flight work |
| `/super-board run <slug> [--low\|--high]` | The loop, until the board drains or a halt gate fires; also resumes |
| `/super-board stop` | Posts "stopped mid-flight" notes, releases claims, stops workers |
| `/super-collect [sentry\|posthog\|github\|prs\|architecture] [--since 30d]` | Finds problems, verifies each, files them into Backlog (dry-run first) |
| `/ui-refine-loop <route>` | Polishes one page or component in critique → refine rounds |
| `/visual [recap\|plan\|<path>]` | One HTML page of a branch, a plan, or part of the codebase |

## Guards

Run automatically once installed. Python stdlib, JSON in, JSON out.

| | |
| --- | --- |
| [guard-worktree-path](hooks/guard-worktree-path.py) | Blocks `git worktree add` outside `.claude/worktrees/` |
| [guard-secrets](hooks/guard-secrets.py) | Blocks reading or piping dotenv files, SSH keys and credential files |
| [guard-key-literals](hooks/guard-key-literals.py) | Blocks a live-looking API key written into a file; flags one already there |
| [guard-delete-outside](hooks/guard-delete-outside.py) | Blocks `rm`, `find -delete` and `git clean` aimed outside the project, `~` or `/` |
| [guard-protected-push](hooks/guard-protected-push.py) | Opt-in (`onboard` asks, or `install.sh --protect-main`): blocks direct and force pushes to main/master/base |
| [README sync](scripts/super-board-readme-sync.py) | Regenerates this skill table; pre-commit and PostToolUse hooks keep it fresh |
| [cleanup-wt](hooks/cleanup-wt.py) | Removes merged worktrees and branches after each merge and at session start, with a recovery file |
| [merge gate](scripts/super-board-merge-gate.sh) | Merges only after the current base plus your `verify_commands` pass, pinned to the reviewed commit |

## Setup notes

- Needs Claude Code, `gh` (authenticated for the board's owner), `jq`, bash 3.2+ and Python 3.
- The board is a GitHub Project (v2) with a `Status` field: `Ready, Building, QA, Review, Done, Blocked, Skipped` (`qa-only` drops `Building`), plus a holding column such as `Backlog` for filed cards.
- Default backend is in-session dynamic workflows: turn them on in `/config`. Headless `claude -p` is opt-in (`worker_backend: "claude-p"`).
- Set `verify_commands` in the config. Without them the merge gate cannot prove the result builds, and says so.
- Auto-merge on the workflow backend needs `Bash(gh pr merge:*)` in your allowlist; `human_approves_merge: true` keeps a person on every merge.
- To enable the usage check, add `printf '%s' "$input" | bash <repo>/.claude/bin/super-board-usage.sh record` to your status-line script.
- Cards need acceptance criteria: QA grades against them, and `lint` tells you which are missing.

## Learn more

- [How it works, safety controls, configuration, limits](docs/super-board/README.md)
- [Release notes](RELEASE-NOTES.md) · [Evals](evals/README.md) · [Config schema](skills/super-board/references/config-schema.json)

## Credits

- Designed and maintained by Eric Tech. MIT, see [LICENSE](LICENSE).
- Skill structure inspired by [obra/superpowers](https://github.com/obra/superpowers).
- Lanes run on the [mattpocock/skills](https://github.com/mattpocock/skills) process stack.
- super-collect and visual adapt [BuilderIO/skills](https://github.com/BuilderIO/skills) (MIT); visual's diagrams follow [tt-a1i/archify](https://github.com/tt-a1i/archify) (MIT).
- ui-refine-loop, the cleanup-wt hook and guard-worktree-path come from Eric Tech's BookKeepingApp.

---

Skills load on a description match. Commands you type. Guards run on their tool events. Adding a skill? Write its `SKILL.md` and `README.md`, add a line to `skills/families.json`, and the README updates itself.
