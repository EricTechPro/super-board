# super-board

Drag a card into `Ready`, walk away, come back to a merged PR with evidence: **7 skills** — 5 primary, 2 secondary — 9 commands, 8 guards.

![Skills](https://img.shields.io/badge/skills-7-000000?style=flat-square)
![Version](https://img.shields.io/badge/version-3.0.0-000000?style=flat-square)
![Host](https://img.shields.io/badge/host-Claude%20Code-000000?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-000000?style=flat-square)

[![Watch the super-board walkthrough on YouTube](https://img.youtube.com/vi/nX_bGyIOFM4/maxresdefault.jpg)](https://youtu.be/nX_bGyIOFM4)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/EricTechPro/super-board/main/get.sh | bash   # in your project folder
```

```
🧩 super-board installer
🔍 checking what you need
   ✓ curl · tar · python3 · gh · jq · node
📦 downloading EricTechPro/super-board@v3.0.0
🔧 installing
   ✓ skills, scripts and workflows → .claude/
   🛡️  6 guard hooks → .claude/settings.json (backup kept)
🧠 helper skills: installed
🎉 super-board 3.0.0 is installed
👉 next: open Claude Code here and run /super-board onboard
```

Or from a checkout: `./install.sh [--no-hooks] [--protect-main] /path/to/your-project`. Then, inside
Claude Code: `/super-board onboard` (8 steps, Enter takes the recommended answer), move cards to
`Ready`, `/super-board run <slug>`.

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
| `/super-board onboard` | 8-step setup: 🔍 Checks · 🔑 GitHub · 🗂️ Board · 🌿 Branch · 📜 AGENTS.md · 🛡️ Policies · 📥 Bug sources · ✅ Review; re-run resumes or upgrades |
| `/super-board lint` | Flags vague ACs and unreadable `Blocked by` lines before agents spend tokens |
| `/super-board status` | Read-only board snapshot, column counts, in-flight work |
| `/super-board run <slug> [--low\|--high]` | The loop, until the board drains or a halt gate fires; also resumes |
| `/super-board stop` | Posts "stopped mid-flight" notes, releases claims, stops workers |
| `/super-collect [sentry\|posthog\|github\|prs\|architecture\|<custom>] [--since 30d]` | Finds problems, verifies each, files them into Backlog (dry-run first) |
| `/ui-refine-loop <route>` | Polishes one page or component in critique → refine rounds |
| `/visual [recap\|plan\|<path>]` | One HTML page of a branch, a plan, or part of the codebase |

## Guards

Run automatically once installed. Python stdlib, JSON in, JSON out.

| | |
| --- | --- |
| [guard-worktree-path](hooks/guard-worktree-path.py) | Blocks `git worktree add` outside `.claude/worktrees/` |
| [guard-secrets](hooks/guard-secrets.py) | Blocks reading or piping dotenv files, SSH keys and credential files; key names via `super-board-env-check.sh` |
| [guard-key-literals](hooks/guard-key-literals.py) | Blocks a live-looking API key written into a file; flags one already there |
| [guard-delete-outside](hooks/guard-delete-outside.py) | Blocks `rm`, `find -delete` and `git clean` aimed outside the project, `~` or `/` |
| [guard-protected-push](hooks/guard-protected-push.py) | Opt-in (`onboard` asks, or `install.sh --protect-main`): blocks direct and force pushes to main/master/base |
| [README sync](scripts/super-board-readme-sync.py) | Regenerates this skill table; pre-commit and PostToolUse hooks keep it fresh |
| [cleanup-wt](hooks/cleanup-wt.py) | Removes merged worktrees and branches after each merge and at session start, with a recovery file |
| [merge gate](scripts/super-board-merge-gate.sh) | Merges only after the current base plus your `verify_commands` pass, pinned to the reviewed commit; applies `merge_policy` and runs allowed DB migrations |

## Setup notes

- Needs Claude Code, `gh` (authenticated for the board's owner), `jq`, bash 3.2+ and Python 3.
- The board is a GitHub Project (v2) with a `Status` field: `Backlog, Ready, Building, QA, Review, Blocked, Done`. `onboard` reuses your best-matching board (adding what is missing, keeping every card) or creates one.
- Three labels route cards: `qa` skips Building (test what exists), `bug` and `feature` are built first; no label is built too.
- Default backend is in-session dynamic workflows: turn them on in `/config`. Headless `claude -p` is opt-in (`worker_backend: "claude-p"`).
- Set `verify_commands` in the config. Without them the merge gate cannot prove the result builds, and says so.
- `onboard` fixes what the board needs without asking (skills, scripts, workflows, guards, settings, old folders, config keys) and asks only to install a system tool or sign in. An older super-board is upgraded in place (see [Upgrading from 2.x](RELEASE-NOTES.md#upgrading-from-2x)).
- `onboard` asks once what the robot may do: auto-merge normal changes up to 400 changed lines (money, auth, destructive schema like DROP/TRUNCATE/RENAME, and bigger PRs wait for you; additive migrations run only on the databases you allow, never live), protect main, and which databases it may migrate (default test + staging). Anything only you may run lands in Blocked tagged 🙋 with the exact command; comment `done` and the next wave merges.
- Auto-merge needs the merge-gate and `gh pr merge` lines in your allowlist; `onboard` offers them as a diff.
- `onboard` can make AGENTS.md the source of truth (CLAUDE.md becomes `@AGENTS.md`) and keeps a managed super-board section in it. Plugin install: the command is `/super-board:super-board onboard`, and its 🔍 Checks step installs the missing scripts, workflows and hooks.
- Bug sources take any extra source in onboard — a link, app name, API URL, MCP server or command — proven readable (read-only) before it is saved; `/super-collect` runs it like the built-ins.
- Testing a live site with no repo is not a board: `/super-qa <url>` runs on its own.
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
