# Release notes

## v3.1.1 — 2026-10-04

`/super-board run` inside a Codex session runs on Codex instead of failing.

- ✨ **A Codex host means `--codex`.** With no Workflow tool, or when the new
  `scripts/super-board-host.sh` prints `codex`, a plain `run` takes the Codex ladder; `--low`,
  `--high` and `--codex=<model>` still apply. The check reads `CODEX_THREAD_ID` /
  `CODEX_SESSION_ID`, which codex-cli 0.160.0 sets in every shell it runs.
- 📝 **How Codex finds the skill.** Codex has no `/super-board` command: it reads skills from
  `.agents/skills/` and is invoked as `$super-board run`.

## v3.1.0 — 2026-10-04

The board spends about a twentieth of the GitHub budget it did, can run every lane on Codex,
and steps itself down when it hits the hourly limit anyway.

- ⚡ **About 20x fewer GraphQL points.** A new `scripts/super-board-card.sh` moves and reads
  cards with cached project and field ids — 1 point a move, where `gh project item-list`
  plus `field-list` cost ~300 on a 131-card board. Comments, labels and PR reads go over
  REST. Measured before: a 3-card wave spent ~2,850 of 5,000 points/hr.
- 📏 **An honest quota reading.** `gh api rate_limit` misreports the GraphQL bucket (REST
  said used=2 while GraphQL said used=930). `sb_gh_quota_merge` in `super-board-gh-guard.sh`
  takes GraphQL's own `rateLimit` numbers; the guard and the summary use it.
- 🤖 **Second account onboarding.** Onboard offers a robot GitHub account so the board gets
  its own 5,000 points/hr (`references/second-account.md`).
- ✨ **`run --codex[=<model>] [--low|--high]`.** Every lane runs on headless Codex
  (`super-board-codex-wave.sh` → `super-board-codex-lane.sh`), cards in parallel under
  `max_workers`. Ladders: Sol/Sol/Astra by default, Luna/Sol/Sol on `--low`, Astra on
  `--high`; a Luna router grades each Ready card. `--codex=<model>` or `codex.model` pins one.
  Review and merge on Codex need the explicit flag; the usage fallback
  (`usage_fallback: "codex"`, now required) builds and tests only.
- 🐢 **Throttle.** `super-board-throttle.sh` lowers `max_workers` after a wave that hit the
  hourly limit — unlimited → 3 → 2 → 1 — and writes it to the config.
- 🧭 **Preflight sequences overlapping peers.** Two Ready cards naming the same files, with
  no open PR, go one at a time: the lower number builds, the other waits behind it. Before,
  each was sequenced behind the other and neither was built.
- 🗄️ **Migration reach checks.** `migrations.checks[env]` is a read-only probe run before the
  first wave, so a broken database URL halts the run instead of a merge.
- 📝 **Models table** in the README; `--high` is now Opus for every card.

## v3.0.5 — 2026-10-03

Migrating a board no longer leaves its cards with no status.

- 🐛 **Every option rewrite is undone.** Rewriting the Status options gives every option a
  new id and clears the Status of every card. `board-migrate --prune-empty` rewrote them
  without restoring, so a live board's cards all fell to "No status". The restore now runs
  after any rewrite, whatever triggered it.
- 💾 **Snapshot on disk first.** Before the first rewrite, every card's status is saved to
  `.claude/super-board/backup/board-<number>-<ts>.json` (path in `status_backup`), so a run
  that dies mid-way can still be put back.
- 🔎 **Snapshot that cannot be empty by accident.** When `gh project item-list` surfaces no
  `status` key on any card, statuses are read over GraphQL instead; item reads now go past
  500 cards.
- 🧪 **Regressions.** Offline scenarios cover prune-empty on a board in use, the GraphQL
  fallback, and a dry run that writes nothing.

## v3.0.4 — 2026-10-03

The skill map reads from left to right, with nested skill families and clearer drill-down
views. The landing board and impeccable map follow the same visual flow.

- 🗺️ **Skill map redesign.** Nested families group related skills; main-step views reveal
  the work in order. Click highlights keep a selected path visible, bullet details make
  each node easier to scan, and the column browser opens related views side by side.
- 💄 **Landing board polish.** Column colours distinguish each lane in light and dark
  themes, with Done before Blocked. Skill-map links use the public Pages route.
- ➡️ **Impeccable map.** The main rail reads left to right through setup, planning,
  diagnosis, optional refinements and polish, with utilities in a separate lane.

## v3.0.3 — 2026-10-03

Refreshing a vendored installation now preserves skills and helpers that already point at
the source pack through symlinks.

- 🐛 **Safe local refresh.** `install.sh` recognizes the same source and destination before
  clearing skill contents or copying scripts, workflows, and hooks. Existing links stay intact.
- 🔒 **Overlapping paths refused.** A destination that contains the source pack or overlaps
  its source skill is rejected before any skill is replaced, preventing deletion or recursive copy.
- 🧪 **Installer regressions.** Disposable fixtures cover two layers of skill links, linked
  helper files, repeated refreshes, and both directions of source/destination nesting.

## v3.0.2 — 2026-10-02

A rewritten README, a GitHub Pages site at https://erictechpro.github.io/super-board/, and map
Source links that work away from a checkout.

- 📝 **README rewrite.** Kanban logo and pitch "Add tasks, walk away, get merged PRs with proof.",
  true counts (7 skills: 4 you type, 3 the board runs · 8 commands · 6 guard hooks), the skill map
  as the hero image, a link to the live site, install by one-liner or plugin, a three-step quick
  start and a commands cheat sheet. The old Setup notes moved to `docs/super-board/README.md`.
- 🌐 **GitHub Pages site.** `.github/workflows/pages.yml` publishes only the public pages: a
  landing page (`/`) with the live skill map, a one-card board walkthrough, the 7 skills and the
  install tabs; `/skill-map/`; `/onboarding/`, a step-by-step setup simulator for the 3.0.2
  install and 8-step onboard; `/impeccable/`; and `/writing-standard/`, a read-only reference
  built from the chosen formats. Pick-a-design pages stay out of the site.
- ♻️ **Skill groups.** `skills/families.json` now groups skills as "You type" (super-board,
  super-collect, ui-refine-loop, visual) and "The board runs" (super-build, super-qa,
  super-review). `super-board-readme-sync.py` keeps every "N skills (N you type, N the board
  runs)" count and the family titles in step.
- ✨ **`/visual render --source-base URL [--source-root DIR]`.** Node sources under the source root
  become links to the hosted file (`:12-20` → `#L12-L20`); others show as text. The skill-map
  pages are re-rendered against `https://github.com/EricTechPro/super-board/blob/main/`.
- 🧪 `test-readme-sync.sh` no longer needs a skills badge, and checks both counts and the family
  titles after a sync.

## v3.0.1 — 2026-10-02

Fixes the red Linux CI on v3.0.0 and stops diagram pages from publishing local machine paths.

- 🐛 **CI on Ubuntu.** `tests/test-setup.sh` hid `gh` with `PATH=/usr/bin:/bin`, but GitHub's
  ubuntu runners ship `gh` in `/usr/bin`. The test now runs the check on a curated PATH (git and
  the package manager only), so a missing `gh` is reported on every OS.
- 🐛 **Merge gate on bash 4+.** `super-board-merge-gate.sh` used `${#VERIFY[@]:-0}`, a bad
  substitution on bash 4+ (Linux), so every merge with a matching head failed. Now `${#VERIFY[@]}`.
- 🔒 **Repo-relative diagram sources.** `/visual` wrote absolute paths (home folder, worktrees,
  plugin cache) into map pages. Sources are now repo-relative (`~/…` outside the repo), the page
  stores the repo root relative to itself, and the skill-map pages are re-rendered.

## v3.0.0 — 2026-10-02

Onboarding rebuilt as an 8-step wizard, one board shape for every project, and labels that
route cards. **Breaking:** the Skipped column, the per-board `variant`, the goal question and
URL-only boards are gone; commits, tickets, PR bodies and comments follow the writing standard.

### Breaking

- **No Skipped column.** Every board is Backlog · Ready · Building · QA · Review · Blocked · Done.
  A card dropped on purpose is closed as not planned and moved to Done with a `🤷 dropped`
  comment. The run's done condition, the landed-work signal, status, lint and the block template
  no longer know Skipped.
- **Labels route cards, not `variant`.** Three labels: `qa` (Ready → QA → Review → Done, skips
  Building), `bug` and `feature` (built first). No label is built too, and the haiku classifier
  adds `feature` or `bug` — never `qa`. `super-board-wave-plan.sh` puts `lane` and `labels` on
  every card; `super-board-wave.js` and the legacy runner route on them. A config that still says
  `variant: "qa-only"` is refused (exit 65) until onboard upgrades it.
- **No goal question, no URL-only board.** Onboard always sets up a repo board. Testing a live
  site alone is `/super-qa <url>`.
- **Writing standard.** Commits `<emoji> [type] scope: subject` + short bullets; tickets Problem ·
  Context · Fix · Acceptance Criteria · Risk · Blocked by; PR bodies in marker blocks; comments
  `[role] [label] status` (references/writing-standard.md).

### Onboarding

**8 steps, each one question.** 🔍 Checks · 🔑 GitHub · 🗂️ Board · 🌿 Branch · 📜 AGENTS.md ·
🛡️ Policies · 📥 Bug sources · ✅ Review. Each opens with a numbered agenda strip and
`N of 8 · <emoji> <Name> — <why>`; the start screen lists the steps; a re-run shows the saved
answers and continues.

**Checks fixes, it doesn't ask.** `scripts/super-board-setup.py fix` installs or refreshes skills,
scripts, workflows, guard hooks and their settings entries, removes the super-refine / cleanup-wt
/ arch-loop folders, migrates config keys, runs `git init` and adds Matt Pocock's skills — backed
up first, listed under "Fixed for you". Only a system tool install (the exact brew / apt / dnf /
winget command) or a sign-in is asked, through Claude Code's permission prompt; it re-checks until
green.

**Board.** `board-rank` lists your GitHub Projects ranked by matching columns and recommends the
best (≥ 4 of 7); `board-migrate` adds the missing columns and the three labels and keeps every
card. A new board gets two names from package.json / README / the folder, or one you type.

**Branch.** No staging → "Create staging from main" (Recommended) runs `git push origin main:staging`.

**Policies** is two questions (safe defaults; N permission lines), details folded.
**Bug sources** adds "➕ Add another source" (below). **Review** is one compact table and
"Write everything?"; files change once, there. **Done** is three lines and a 🎉.

**🙋 Needs you, checklist first.** The comment opens with "🙋 Your turn on #N — title", the exact
commands as checkboxes and "Comment done here"; why and evidence fold under "Why, and what I
checked".

### super-collect custom sources

Onboard's "➕ Add another source" takes a link, app name, API URL, MCP server or CLI command.
`collect_custom.py classify` decides which, `ping` proves it is readable (read-only; commands that
change something are refused), `add` saves `{name, kind, target, auth_env?, map?}` to
`collect.custom[]`. `/super-collect` runs them (`list`; MCP reads go through the agent and
`normalize`), turns the output into candidates with fingerprint `custom|<name>|<key>`, and sends
them through the same verifier and filer (`--source custom`).

### Install output

`get.sh` and `install.sh` print grouped lines with emojis (🧩 🔍 📦 🔧 🧠 🎉 👉) instead of one line
per file; failures still name the file. `install.sh` records an older install in
`.claude/super-board/upgrade.json` for onboard.

### Upgrading from 2.x

> [!WARNING]
> `board-migrate` (step 2's board changes) is tested only against a stubbed `gh`, never a live
> GitHub project. Try it on a throwaway board first: copy your project, run
> `python3 .claude/bin/super-board-setup.py board-migrate --owner <o> --number <copy> --repo <r> --dry-run`,
> then without `--dry-run`, and check the columns, labels and card statuses before you run
> onboard on the real board.

1. Install over the old copy: `curl -fsSL https://raw.githubusercontent.com/EricTechPro/super-board/main/get.sh | bash`
   (or `./install.sh <project>`). It records the version you came from.
2. Run `/super-board onboard`. Step 1 upgrades with no question and lists it under
   "Upgraded for you" (backup in `.claude/super-board/backup/<ts>/`):
   - removes `.claude/skills/super-refine`, `cleanup-wt`, `arch-loop`;
   - config: drops `variant` (a "qa-only" board's cards get the `qa` label), sets the seven
     `columns`, turns a URL-only `target` into a repo target, replaces the old `collect` keys
     (`errors`, `feedback_paths`, `lookback_runs`) with `sources`, drops
     `refine.qa_hook_rounds`, adds `merge_policy` (from `human_approves_merge`), `migrations`,
     `timezone`, `worker_backend`, and sets `notifications.channel` to `session`;
   - board: adds missing columns, creates `qa` · `bug` · `feature`, maps old labels
     (build → feature, bug-fix → bug, qa-only → qa), moves Skipped cards to Done and removes the
     Skipped option. Card statuses the change clears are put back.
3. Your CLAUDE.md rules stay where they are; step 5 offers to move them into AGENTS.md.
4. A run started on an unmigrated `qa-only` config stops with exit 65 and says to run onboard.

### Tests

New `tests/test-setup.sh` (9: must-have fixes, upgrade detection and migration, idempotent config
migration, tool commands, board names, staging, board ranking and migration with a stateful `gh`
stub) and `tests/test_collect_custom.py` (17). Label routing in `test-wave-plan.sh`,
`test-wave-preflight.sh` (10) and `test-run-gates.sh`; grouped output in `test-install.sh` (13)
and `test-get.sh` (9); the 🙋 checklist in `test_writing_format.py` (14).

## v2.6.0 — 2026-10-02

Cleanup release: one renamed skill, one skill turned into a hook, super-collect rebuilt, arch-loop
removed, three new guards, two new evals and a sweep of stale docs.

### Skills

**ui-refine-loop, renamed from super-refine and rebuilt on Impeccable.** A standalone helper
(secondary) under `/ui-refine-loop`; the board no longer runs it (run.md Tester step 5b, the QA
lane prompt hook and `references/qa-hook.md` are gone; `refine.qa_hook_rounds` is ignored). It
reads the target's code, grills at most 10 questions in waves into a per-project taste file
(`docs/design/taste.md`, from a neutral default), then runs bounded rounds: an isolated design
reviewer and detector, a checker that ranks typed problems, and a fixer that routes each type to
an Impeccable command (polish last). Shots cover light and dark at 1440 and 390, with section
crops and before | after sheets. The score is design /20 + audit /20, not Nielsen. Default 5
rounds, stopping after two checks with no P0/P1. A finish reviewer grades each fix, and it ends in
a draft PR with a Before | After table (raw GitHub URLs). Impeccable v4.0.x (`node
scripts/detect.mjs`) and v4.4+ (`scripts/impeccable`) are both detected, parent dirs included; a
missing install now warns loudly instead of silently falling back to the rubric.

**cleanup-wt is a hook now, not a skill.** The script moved to `hooks/cleanup-wt.py` and ships
with the guard hooks. The merge gate still runs it with `--post-merge` after every merge, and the
`SessionStart` `--auto` sweep is now part of the default `hooks/settings-snippet.json` (it was an
opt-in block). It leaves the skill tables and is listed under Guards. An old install's
`.claude/skills/cleanup-wt/` can be deleted by hand.

**super-collect, rebuilt as source plug-ins.** One job: find problems and file them into the
project's Backlog. Sources `sentry` (REST), `posthog` (HogQL; exceptions, failure events, rage and
dead clicks, web vitals, surveys, tracking gaps), `github` (unboarded issues, adopted), `prs`
(recurring problems across merged PRs' comments, reviews and super-review reports, one GraphQL
search) and `architecture`; run one (`/super-collect sentry`) or all. `--since` picks the window
(default 14 days). Each candidate goes to one fresh verifier (real, still happening, already
fixed, duplicate); unclear ones file as `needs-triage`. The `intake`/`lookback` modes, feedback
folders and run-file lookback are gone; the config's `collect` block is replaced (sources,
sentry/posthog IDs and thresholds; secrets stay in `.env`), and onboard gains step 11b to set it
up and test each connection read-only. Tests: `tests/test-collect-fetchers.sh` (new, stubbed
HTTP), `tests/test-collect-file.sh` 30 → 47 cases.

**arch-loop folded into /super-collect architecture.** The skill is removed; architecture findings
are now read-only refactor tickets in Backlog instead of an implement loop.

### Guards

**No deleting outside the project (on by default).** `hooks/guard-delete-outside.py` denies `rm`,
`rmdir`, `unlink`, `find … -delete` / `-exec rm` and `git clean` aimed outside
`$CLAUDE_PROJECT_DIR`, and always `/` or `~`. Temp dirs stay deletable inside.

**Protected-branch push guard (opt-in).** `hooks/guard-protected-push.py` denies direct and force
pushes (`-f`, `--force`, `--force-with-lease`, `+ref`, `--delete`, `--all`/`--mirror`) to main,
master and the config's `base_branch`; force pushes to feature branches stay allowed.
`super-board onboard` asks once (step 9b) and `install.sh --protect-main` wires it
(`hooks/settings-protect-main.json`).

**Skill-eval gate (pack and EricOS only).** `hooks/dev/gate-skill-evals.py`, a Stop hook adapted
from the starter kit's `gate-skill-evals.sh`: a skill changed this session (uncommitted or
unpushed) with no newer `claude plugin eval` result blocks the stop and names the command. A changed
reference or workflow counts only for a skill with an eval case; a `SKILL.md` with no case only
warns. Never installed into targets; wired in this pack's `.claude/settings.json`.

Tests: `tests/test-guard-hooks.sh` grows from 25 to 77 cases; `tests/test-install.sh` gains
scenario 10 (`--protect-main`) and checks that `hooks/dev/` is never installed.

### Evals

Two new `claude plugin eval` cases beside `review-remembers`, same offline `gh` stub and scaffold:

- **`ponytail-overengineering`** — a correct, tested PR wraps a one-line price formatter in a
  strategy class, registry, factory and JSON config. super-review must report an Over-engineering
  finding routed to Super Build and still call the PR merge-ready. 3/3 runs passed ($0.82).
- **`test-gap`** — AC 2 of a slugify PR (≤ 50 characters) has no test. super-qa's test-gap check
  must rank it High and write the test red-first or bounce to Build. 3/3 runs passed ($1.21).

The `gh` stub now serves a per-case `issue.json` for `gh issue view`.

### Stale docs swept

- **Telegram** is gone from every lane and reference: super-board sends no messages of its own.
  `notifications.channel` is now `"session"` and `chat_id` is reserved (config-schema, onboard
  step 10, run.md block-rate alert, run-workflow.md wave report, super-build, super-qa, super-review).
- **super-qa standalone loop** no longer calls `scripts/super-qa-dispatch.sh`, which never shipped:
  each iteration is a sub-agent launched in-session, with the same 0/2/3/4/5 statuses. Dropped the
  missing `docs/super-orchestrator/STAGING-ENV.md` link, the leftover app-specific spec list, and
  "phone-only via Telegram".
- **super-ux** (never a skill) → `ui-refine-loop` as a suggested owner in super-qa, its preamble and
  `super-qa-file-bug.sh --suggested-skill`.
- **super-board SKILL.md** said `run` is headless via `super-board-run.sh`; it is in-session by
  default. Removed every pointer to `docs/specs/2026-05-21-super-board-design.md`, which does not
  ship (SKILL.md, onboard, lint, status, stop, run, block-template, config-schema), and the
  `super-work-trader` line. run.md now says it holds the lane lifecycles plus the legacy runner.
- **super-build** dispatcher path is `.claude/skills/super-build/scripts/super-build-dispatch.sh`;
  removed the `Fitbox Admin` example. super-review is "the super-board reviewer", not EricTechOS's.
- **CLAUDE.md**: eight skills, not nine; product work goes to workflow lane agents, not only
  `claude -p`; the install contract matches what `install.sh` copies; script paths are `.claude/bin/`.
- Version 2.6.0 in `VERSION`, `skills/super-board/VERSION`, `plugin.json` and the README badge.

### Also

**Onboarding rebuilt (16 gaps).** Install and workflow-runtime checks run first (step 2), so a
missing `super-board-wave.js` halts before any question; a plugin install (`/super-board:super-board
onboard`) detects the missing bin scripts, workflows, hooks and Matt Pocock's skills and installs
them from the plugin's own copy. Every question leads with a `(Recommended)` option. Answers save
to `.claude/super-board/onboard-answers.json` as they come: a halt resumes where it stopped, and a
re-run offers keep all (check and repair) or edit which. Merge policy, protect main (asked once;
with `--no-hooks` it is never wired to a missing script) and migration envs share one Policies
screen with "Accept all recommended". The allowlist (merge gate, `gh pr merge`, migrate commands)
is offered as a diff up front. Collect sources are pinged before one review screen, and the config
is written once. URL-only boards skip git; option D is check and repair; the ticket format lives
once, in `docs/agents/issue-tracker.md`. `install.sh` ends with one line: run `/super-board onboard`.

**AGENTS.md as the source of truth.** Onboard asks to merge CLAUDE.md into AGENTS.md (backup
first; rule units, duplicates once, conflicts asked one by one quoting both lines, every unit
mapped to a line, diff and approve) and leaves CLAUDE.md as `@AGENTS.md` plus any Claude-only
rules. A managed super-board section (tables, terse, NEVER/DON'T in caps, which skill when) sits
between `<!-- super-board:begin -->` / `<!-- super-board:end -->`; re-install rewrites only that
block, and a CLAUDE.md that is no longer a pointer gets the merge offered again. Deterministic
parts in `scripts/super-board-agents-md.py` (detect, backup, block, pointer, units, coverage,
check, atomic writes).

**Merge policy.** New `merge_policy`: normal changes auto-merge; money, auth and destructive schema
(labels, path globs, added-line keywords, all configurable) and diffs over `auto_max_lines` always
go to a human. The merge gate decides (`scripts/super-board-merge-policy.py`) and exits 7; the card
goes to Blocked with 🙋, and the human merges it or comments `done` to approve.
`auto_max_lines` defaults to 400 changed lines (additions + deletions; `0` turns it off); lockfiles,
generated files and snapshots (`size_exclude`, configurable) and migration SQL (reported
separately) do not count. Over the cap → 🙋 "big PR — please review". "Schema" means destructive
only (DROP / TRUNCATE / RENAME, or the `schema` label); additive migrations follow the
`migrations` database rule, and a live database is always human.

**Small PRs by design.** Lint criterion 15 and the Builder pre-flight flag a ticket likely to exceed
~400 changed lines or spanning many areas as "too big": held with ❓, split via `/to-tickets` into
vertical slices. The Builder keeps each PR under the cap; growing past it mid-build, it stops and
proposes the split in a PR comment instead of pushing on.

**DB migrations at merge.** New `migrations` block: onboard asks which databases the robot may
migrate (test / staging / live, default test + staging). A PR touching the migration globs gets
the configured migrate command run against each allowed env inside the merge lock, after verify.
A target env that is not allowed, a failed command, or a declared human step (`needs-you:` in the
PR body, `migrations.human_steps`) exits 8: Blocked with 🙋 and the exact commands. A `done`
comment or the `needs-you:done` label puts the card in the planner's new `resume` list → Review →
the gate re-verifies and merges.

**🙋 Needs you** reason tag in `block-template.md`, for any step only a human may run. There is no
extra column: Blocked + 🙋 + the `needs-you` label.

**Helpers.** `scripts/super-board-env-check.sh` prints present / empty / missing per env key and
never a value; `guard-secrets.py` allows a plain call to it. `scripts/super-board-settings.py`
merges hooks and permission rules into settings.json (backup, atomic, `--dry-run` diff);
`install.sh` uses it, and `--no-hooks --protect-main` now installs only the push guard.

Tests: new `test-env-check.sh`, `test-agents-md.sh`, `test-settings.sh`; `test-merge-gate.sh`
13 → 26 scenarios, `test-deps.sh` 17 → 18, `test-wave-plan.sh` 17 → 18, `test-install.sh` 10 → 12,
`test-guard-hooks.sh` 77 → 82 cases.

## v2.5.0 — 2026-10-02

Review remembers, sharper lanes, five new skills, guard hooks, and a pack that installs and
documents itself.

### Review

**Review remembers.** A card rebuilt after a Review bounce used to meet a reviewer with no memory of
the last pass: settled points were re-litigated, and a builder could resolve a thread without
fixing the code. The Reviewer now loads `prior_report`, the newest PR comment carrying
`<!-- super-review:report -->` (one `gh pr view` call). Round 1 marks each prior finding `fixed`,
`not fixed` or `no longer applies` with the file:line that proves it; a resolved thread is not
proof. Any `not fixed` bounces the card again and the fresh pass is skipped; all clear → the normal
review runs as round 2 (run.md → Reviewer step 3b). Every Reviewer exit from step 3b posts a report
with stable finding ids (`R1`, `R2`, …) carried across rounds. No report means a first review,
unchanged. The Builder side only gains a note that a re-opened thread was resolved without a fix.
The wave's Review prompt carries the step and `STAGE_SCHEMA` gains an optional `priorFindings`
count. Test: `tests/test-wave-review-memory.sh` (also the wave script's syntax check: plain
`node --check` rejects a workflow body's top-level `return`).

**Eval.** `evals/review-remembers/` runs the behaviour end to end with `claude plugin eval`: an
offline `gh` stub serves a PR whose prior report lists R1 (really fixed) and R2 (thread resolved,
code unchanged). The reviewer must load the report, mark R1 fixed and R2 not fixed with file:line
proof, bounce, and never call `gh pr merge`. 3/3 runs passed on release. See `evals/README.md`.

**Fairer review.** The Reviewer reads the ACs and the raw diff and writes 2-4 hypotheses before it
reads the builder's summary, then checks the builder's claims the same way. Findings are classed
Gap / Bug / Verification miss / Scope drift / Over-engineering. Checks that held go under
`Verified`, coverage gaps under `Not verified`, and `Next` names the owner. Marker, R-ids and Prior
findings are unchanged.

**Merge pinned to the reviewed head.** The Reviewer records `headRefOid` when review passes and
passes it to `super-board-merge-gate.sh --expect-head`. The gate verifies that commit and merges
with `--match-head-commit`. A push after review, or during verify, exits 6: the evidence is void
and the card stays in Review. Tests 8-11 in `tests/test-merge-gate.sh`.

### Lanes

**Docs before outside-tool code.** When a ticket touches a third-party API or SDK, an upgrade, or
auth/billing, the Builder reads the current official docs for the installed version (context7,
else the vendor's site) first and cites them in a `Docs consulted` PR section. Unreachable docs are
named and the code they cover is marked unverified (run.md Builder step 3b, super-build).

**Simplest solution first.** Builders invoke `ponytail:ponytail` (full) before the first line of
code on every type label, or a five-line inline ladder when the plugin is absent
(decision-policy.md → "Simplest solution first"); it never cuts validation, security, data-loss
protection or accessibility. The Reviewer runs `ponytail:ponytail-review` on the merge-base diff;
an **Over-engineering** finding is Should fix, routed to Builder, and never blocks or bounces alone.

**Test-gap check in QA.** Before its test run the Tester maps every AC to unit / component / e2e
tests, marks edge cases with exact witness values, names weak tests and surviving mutants, and
ranks gaps (folded from post-tdd). High gaps are written red-first through `tdd`; one that needs
app code changed bounces to Builder. Medium/Low are listed and never block (run.md Tester step 4b).

**UI polish in QA.** A UI card (label `ui`, `design` or `frontend`, or a visual AC) whose AC tests
passed now gets ui-refine-loop in qa-hook mode, 3 rounds by default (run.md Tester step 5b,
`skills/ui-refine-loop/references/qa-hook.md`). AC tests re-run after it; red resets to the pre-hook
commit. It never moves the card, comments or blocks. The wave's QA prompt carries the condition.

**Tighter writing.** Lane comments follow five rules (run.md → Commenting cadence): outcome first,
evidence (command, sha, file:line) before prose, what was and was not verified, and a closing
`Next:` naming the owner, in 12 lines or fewer. The PR body opens with a status line pinned to the
head sha and gains `Not verified`. The Block template gains `Evidence`, `Checked` and `Owner`. The
wave report and halt note have fixed short formats; only cards that need a human get their own line.

### Run loop

**Stranded Building cards come back.** The planner reports unclaimed Building cards in `stranded`;
the orchestrator removes the leftover build worktree, keeps the branch, moves the card to Ready and
comments. The legacy dispatcher does the same once at start (`reclaim_stranded_building`), and
Builder step 2 continues on an existing branch. Tests: scenarios 16-17 in `test-wave-plan.sh`, six
checks in `test-run-gates.sh`.

**Usage guard before each wave.** New `scripts/super-board-usage.sh`. Claude Code exposes plan
usage only in the `rate_limits` JSON it pipes to the status line: `record` saves it from your
status-line command, and `check` compares the 5-hour and weekly windows against `usage_pause_pct`
(default 95). At or over it, no new wave launches, the running one finishes, a resume note is
posted and, if a wake tool exists, a re-check is scheduled at the reset. Pro/Max only, fresh only
while an interactive status line records, and an unknown reading never halts a run.
Test: `tests/test-usage.sh`.

**Post-merge cleanup.** After a merge the gate runs `cleanup-wt --post-merge --base <base>` when
`.claude/skills/cleanup-wt/` is installed. Local only; a cleanup failure never changes the exit.
Tests 12-13 in `tests/test-merge-gate.sh`.

**Config.** `config-schema.json` gains optional `refine` (ui-refine-loop settings) and `collect`
(`window_days`, `errors`, `feedback_paths`, `lookback_runs`) blocks.

### New skills

- **super-collect** (primary): files app errors, unboarded issues, feedback and repeat failures
  from past runs into Backlog, deduped, dry-run by default. Adapted from BuilderIO/skills (MIT).
  Test: `tests/test-collect-file.sh`.
- **ui-refine-loop** (primary): unattended critique → refine loop on one page or component, with its
  own worktree, dev server, before/after shots and `workflows/ui-refine-loop.js`. Adapted from
  BookKeepingApp. Tests: `tests/test-ui-refine-loop-setup.sh`, `tests/test-ui-refine-loop-workflow.sh`.
- **visual** (secondary): one self-contained HTML page for a branch recap, a plan or a codebase
  map. Adapted from BuilderIO/skills (MIT), diagrams after tt-a1i/archify (MIT).
- **arch-loop** (secondary): architecture review loop, one verified commit per pass.
- **cleanup-wt** (secondary): removes merged worktrees and branches with a recovery TSV.
  Test: `tests/test-cleanup-wt.sh`.

### Guards, install and docs

**Guard hooks.** `hooks/guard-worktree-path.py`, `guard-secrets.py` and `guard-key-literals.py`
(Python stdlib). Test: `tests/test-guard-hooks.sh`.

**install.sh** installs all nine skills, both workflows and the guard hooks, and merges
`hooks/settings-snippet.json` into `.claude/settings.json`: existing keys kept, each command added
once, the file backed up first, invalid JSON left untouched. `--no-hooks` skips the hooks.
`tests/test-install.sh` grows to 9 scenarios. `plugin.json` lists the full pack.

**README.** Rewritten as a short front door; the long material moved to
`docs/super-board/README.md`. Every skill has a README. `scripts/super-board-readme-sync.py`
regenerates the skill tables and counts from SKILL.md frontmatter and `skills/families.json`
(`--check` exits 1 when stale), run by a git pre-commit hook (`hooks/pre-commit-readme.sh`) and a
Claude Code PostToolUse hook (`.claude/settings.json`). Test: `tests/test-readme-sync.sh`.

**Versions.** `skills/super-board/VERSION` was stale at 2.0.0; `VERSION`, `skills/super-board/VERSION`
and `plugin.json` all read 2.5.0.

## v2.4.0 — 2026-08-20

The `Blocked` column stops being a dead end, and nothing merges on GitHub's word.

Everything here came out of one real run in which five cards sat in `Blocked` long after their
blockers had merged, and two PRs that GitHub called mergeable would have turned the base branch red.

**Waves are sized by the dependency graph.** `super-board-wave-plan.sh` now dispatches every Ready
card whose `## Blocked by` issues have all closed, plus whatever is already in flight. `max_workers`
is demoted to an optional throttle — absent or `0` is unlimited, which is the new default. A fixed
cap sized waves badly: on a board where 23 of 32 Ready cards were waiting on an open blocker, it
spent its slots on cards that would hit their own preflight and park.

**The Blocked sweep.** The planner returns a `sweep` list — cards whose blockers have all closed —
and the orchestrator moves them back to `Ready` before launching, so they join that same wave. Cards
gated on a person (`blocked-by: -`) are never swept.

**New: `super-board-deps.sh`.** The dependency primitive. Reads the last `blocked-by:` line from a
card's Block comments, falling back to the body's `## Blocked by` section, and answers
`runnable` / `humanGated` / `parseable` per issue. It is deliberately fail-safe: three shapes that
look like "no blockers" but are not — a missing section, an empty one, and `- None — but #26 must
merge first` — are reported unreadable and flagged rather than guessed at. That third shape is
produced by following the `to-tickets` template, so it is common.

**New: `super-board-merge-gate.sh`.** Takes an atomic `mkdir` merge lock, merges the CURRENT base
into a scratch worktree, runs `config.verify_commands`, and only then squash-merges. Exit codes
route the caller: `2` and `5` mean a rebase pass for the Builder, `3` is a real human block, `4` is
just "someone else is merging". `mergeable: CLEAN` answers only "does the text conflict"; it says
nothing about whether the result compiles.

**The Review lane is no longer serialised.** The promise-chain mutex around the whole Review lane is
gone from `super-board-wave.js`. It guarded the right thing in the wrong place — reading the diff,
rerunning the suite and the truth-check never touch the base branch. The mutex now sits at the merge
step alone, where the race actually is, and is visible across processes and machines.

**Merge conflicts are a rebase pass, not a Blocked card.** `run.md` routes a conflicting or stale
branch back to `Ready` with `loop:rebase`. The Reviewer still never pushes to a branch it is judging
— it hands the work to the lane that is allowed to.

**Lint gains two criteria.** 13: the `## Blocked by` line must be machine-readable. 14: an
acceptance criterion proved against a fake must name the card that builds the real thing, or lint
offers to file it.

### Fixes

- `super-review-file-refactor.sh` and `super-qa-file-bug.sh` filed into hardcoded `Backlog` / `Bug`
  columns. A board without them got cards with **no Status at all** — invisible in the Kanban view,
  not merely misplaced. Both now fall back through the conventional aliases and say which they used.
- `install.sh` handles a `.claude/skills/<name>` that is a **symlink** to a real tree elsewhere,
  resolving it with `cd -P` and writing through it instead of failing with "Not a directory". It
  also refuses any destination not named after the skill, and `test-install.sh` plants decoy
  directories that must survive — because an earlier draft of this resolution deleted 190 of them
  (`cd ""` succeeds in bash, so an empty `readlink` silently resolved to the parent).
- `install.sh` never shipped `super-board-stop.sh`, so a fresh install had a broken `stop` verb.
- README claimed `bash 4+`. Every script here is bash-3.2 clean, which is what stock macOS has.
- README listed the `mattpocock/skills` pack under Credits rather than Requirements, though the lane
  skills reference twelve of them by name and fail without them.

### Tests

`test-deps.sh` (17) and `test-merge-gate.sh` (7) and `test-install.sh` (5) are new.
`test-wave-plan.sh` (15) was rewritten for the new wave contract. `test-file-refactor.sh` gained
five. All offline — no `gh`, no network.

## v2.3.0 — 2026-08-20

**Skills are assigned when the ticket is written, not re-derived at runtime.**
super-build defaulted every card to the same `tdd` + testing set regardless of
what the card was. A docs ticket got told to write a failing test first; a
refactor got no design vocabulary; and `implement` — whose description is
literally "implement a piece of work based on a spec or set of tickets" — never
fired once, because it is `disable-model-invocation: true` and nothing ever
pinned it.

Rule 4 now routes on the issue's **type label**:

| Type label | Loads, in order |
| --- | --- |
| `bug` | `diagnosing-bugs` → `tdd` |
| `feature` | `implement` → `tdd` → `codebase-design` |
| `ux` | `implement` → `tdd` |
| `refactor` / `tech-debt` | `codebase-design` → `tdd` |
| `tests` | `tdd` |
| `docs` | none — skip `tdd`, there is no behaviour to pin |
| *(none)* | `tdd` |

No new label vocabulary: these are the types `super-qa` already files via
`--kind`, plus `refactor` from `super-review`.

- **Order inside a row is load-bearing** — diagnose before writing the red test,
  implement against the spec before reaching for design vocabulary.
- **Always, on top of the row:** `verification-before-completion` before the
  final commit, and one `code-review` pass on the worker's own diff.
- **Test mechanics stay off the label.** `vitest` / `playwright-best-practices`
  are picked by walking the localisation ladder — a `ux` ticket whose defect
  reproduces in a pure function gets a unit test, not a browser spec.
- **Precedence:** an explicit `Skills:` line replaces the row outright rather
  than extending it. Multiple type labels → first matching row, top to bottom.
- `implement` was missing from the Skill map it is now routed to; added.

## v2.2.2 — 2026-08-20

Docs fix, no behaviour change. super-qa cited five `playwright-best-practices`
reference files by bare filename — `locators.md`, `fixtures-hooks.md`,
`test-data.md`, `assertions-waiting.md`, `page-object-model.md`. The skill
(`currents-dev/playwright-best-practices-skill`) ships them under `core/`.

A worker told to read a path that does not resolve reads nothing and falls back
to habit — which is the exact failure the citation exists to prevent. All five
now point at `core/<name>.md`.

The `vitest` citations were checked against the installed skill and are correct:
19 references, and all five named ones (`core-expect`, `features-mocking`,
`features-coverage`, `core-hooks`, `advanced-vi`) exist under `references/`.

## v2.2.1 — 2026-08-20

**`super-qa-file-bug.sh` existed only in prose.** The preamble told workers to
call it, documented its eleven flags, its dedupe policy, and four distinct exit
codes — and the file was never in the repo. Every QA finding that hit that line
died there. It is now written to the spec that was already on the page, and
tested.

- **Body guardrails.** Rejects a body missing any of Summary / Repro steps /
  Expected behavior / Actual behavior / Evidence / Suggested fix path /
  Acceptance criteria, and sweeps for unfilled `TBD`, `TODO:`, and
  `<placeholder>` leftovers outside fenced code — a HAR snippet has angle
  brackets, an unfilled template line has them too, and only one of those should
  block. `SUPER_QA_ALLOW_WEAK_BODY=1` bypasses, as documented.
- **Machinery, not evidence.** The agent writes the findings; the script
  prepends `## Board summary`, appends the hidden `super-qa-meta` block, and
  derives a fingerprint when none is passed. Derivation deliberately excludes
  the iteration number, so the same finding seen on iter 9 dedupes against the
  card filed on iter 3.
- **Project resolution per spec** — `SUPER_QA_PROJECT_OWNER` then the repo
  owner, `SUPER_QA_PROJECT_TITLE` then `Super Ultimate QA`. It halts rather than
  falling back to the repo's primary project, whose columns mean different
  things.
- **The exit-71 contract holds.** When the issue is filed but the board promote
  fails, the number still reaches stdout — the caller logs "manual move
  required" and carries on instead of losing the finding.
- `tests/test-file-bug.sh` — 33 assertions, `gh` stubbed, no network.

**Three doc contradictions the implementation surfaced**, all in
`super-qa/references/iteration-preamble.md`, all resolved toward
`super-qa/SKILL.md` as the more detailed spec:

- Destination column was `Ready` in the preamble and `Bug` in SKILL.md → `Bug`.
- Triage label was `super-qa` in the preamble's carved-exception paragraph and
  `source:qa` everywhere else → `source:qa`.
- The board was named "Fitbox Admin project board (#2)", a leftover from another
  project → the resolved Super Ultimate QA project.

## v2.2.0 — 2026-08-20

**The advisor panel is removed from super-build and super-qa.** It convened
`mattpocock-skills:grilling` inside a worker whose own preamble forbids asking
the user anything — and grilling's contract is "put each question to them and
wait." In practice the worker either stalled or answered its own questions,
which is inline reasoning wearing a costume.

- **New: the decision ladder.** Acceptance criteria → repo precedent → smallest
  blast radius → human gate. Walk it, stop at the first rung that answers the
  question. Replaces "poll five roles, take the majority, tie → smallest blast
  radius" with the tiebreak that was doing the work anyway.
- **`grilling`, `shape`, and `clarify` are now worker-forbidden** and documented
  as `super-board lint`-only. Reaching for one inside a lane is itself a human
  gate — it means the ticket should have been caught upstream, while a human was
  still at the keyboard.
- **`code-review` survives, with a fixed point.** It runs once against the
  worker's own diff before the final commit, with `git merge-base HEAD
  origin/<base>` supplied so it never prompts. Standards findings are fixed in
  place; a Spec finding that contradicts the issue's AC is a human gate.
- **Commit trailer: `--- decision-vote ---` → `--- decision ---`.** Records the
  question, the choice, and which rung settled it. Only rung-3 decisions need
  one; AC and precedent are their own record.
- **Human gates gained two entries** — public-contract breaks, and "you wanted
  to grill the ticket."

**super-review had no skills at all — now it has two.** The reviewer was running
on its own prompt while every other lane loaded a process stack.

- **`code-review` in the Review lane**, both axes. Standards against the repo's
  documented rules plus the Fowler smell baseline; Spec against the originating
  issue's acceptance criteria. The merge-base is always passed as the fixed point
  so it never stops to ask for one. A Spec finding that contradicts the AC is a
  Blocker.
- **`codebase-design` as review vocabulary.** The reviewer now reads the diff for
  shape — module, interface, depth, seam, adapter, leverage, locality — and applies
  the deletion test to anything shallow the diff adds. Scoped to the diff, never the
  whole codebase.
- **New finding class: deepening opportunity.** It never blocks a merge. A green PR
  does not get held for architecture taste.
- **New: `scripts/super-review-file-refactor.sh`.** Files shape problems as
  `refactor` cards in **Backlog** (not Ready — an unrefined card must not feed the
  build lane), deduped by fingerprint, labelled `source:review` and
  `strength:<strong|worth-exploring|speculative>`. It degrades to warnings on every
  failure past issue-create: a board hiccup must never strand a mergeable PR in
  Review. Covered by `tests/test-file-refactor.sh` (17 assertions, gh stubbed).
- **`improve-codebase-architecture` is documented as lane-forbidden.** It scans the
  whole codebase rather than the diff, writes an HTML report and shells out to
  `open`, then asks which candidate to explore and hands off to `grilling`. It is a
  desk tool — point it at the cards this lane files.

Files touched: `super-build/references/decision-policy.md` (rewritten),
`super-build/references/worker-preamble.md`, `super-build/SKILL.md`,
`super-qa/references/iteration-preamble.md`, `super-review/SKILL.md`,
`scripts/super-review-file-refactor.sh` (new),
`tests/test-file-refactor.sh` (new), `install.sh`, `README.md`.

## v2.1.1 — 2026-08-07

Docs only, no behaviour change. The README explained itself in paragraphs where
a diagram reads faster in a terminal.

- **New "At a glance" table** up top — what it does, what you get, how you
  start, what holds state. Previously you read five paragraphs first.
- **"How it works" leads with the lane pipeline** as an ASCII diagram
  (`Backlog → Ready → Building → QA → Review → Done`, with the bounce-back edge
  and the orchestrator underneath), then the skill table.
- **The testing section is two diagrams instead of two screens of prose** — the
  three layers, then the localisation ladder as a box with "found here" at the
  top and "write it HERE" at the bottom.
- **Backends collapsed into a comparison table** (`workflow` vs `claude-p`).
- **Safety controls became a spawn-gate decision tree** — the six guards drawn
  as the checks a worker passes before it starts, rather than a numbered list.
- **Config keys annotated beside the JSON, not inside it.** The JSON block stays
  valid so it survives copy-paste; annotations sit in a plain block underneath.
- **Variants drawn as their lane strips**, so `full` vs `qa-only` is visible
  instead of described.
- Skill structure and the pattern/conductor note became code blocks.

Prose blocks over 200 characters: 8 → 2. Code fences: 8 → 24.

## v2.1.0 — 2026-08-07

Workers now decide *which layer* a test belongs at, instead of defaulting to the
layer the bug was observed at.

### Testing is three layers, not one skill

`mattpocock-skills:tdd` says how to write a test worth having. It is
deliberately agnostic about the *kind* of test — which meant Testers, who find
every bug through a browser by construction, left every regression as a
Playwright spec.

Three layers now, answering different questions:

| Layer | Question | Skill |
| --- | --- | --- |
| Discipline | How do I write a test worth having? | `mattpocock-skills:tdd` |
| Placement | Which layer does this defect live at? | the localisation ladder |
| Mechanics | How do I express it in this repo? | `vitest` / `playwright-best-practices` |

### The localisation ladder

Walk down, stop at the first rung that still reproduces the failure:

1. Call the module directly with the same inputs → **unit** (Vitest)
2. Wire the real collaborators together → **integration** (Vitest)
3. Drive a real browser → **e2e** (Playwright)
4. Only fails against a live third party → not a test; file a mock/contract gap

Write the test at the rung you **stopped on**, not the rung you **found it on**.
Where a bug was observed says nothing about where it lives. The reason is
locality of failure: an e2e pinning a pure-logic defect is slower, flakier, and
goes red pointing at a page instead of a function, so the next person debugs the
wrong file.

### Two gates before a test counts as done

- **Red for the right reason.** Run against the *unfixed* code and read the
  message — it must name the defect. Red from a timeout or a missing selector
  pins the harness, not the bug.
- **Refactor-survivable.** Rewrite the implementation with behaviour unchanged;
  it must still pass.

### New optional skills

`vitest` (`antfu/skills@vitest`) and `testing-strategy`
(`anthropics/knowledge-work-plugins@testing-strategy`). `testing-strategy`
informs *coverage* — what a component type is worth testing and what to skip —
not placement. Contract testing stays out of the default set: Pact solves
consumer/provider drift across independently deployed services, which a
single-app repo does not have.

### Fixed

- `super-qa`'s frontmatter advertised "builds and runs Playwright path specs",
  framing every regression as e2e regardless of what the references said.
  Crawling is still browser-driven; the regression test it leaves behind is not.

## v2.0.0 — 2026-08-06

Two breaking changes ship together: the worker skill vocabulary moves to the
Matt Pocock stack, and "forward progress" is redefined in terms of landed work.

### BREAKING — workers run on mattpocock/skills

`superpowers:*`, the `gstack` CLI and `gsd-*` are no longer dependencies.
Boards that pin skills in an issue's `Skills:` line must update the names:

| Was | Now |
| --- | --- |
| `superpowers:using-superpowers` | `mattpocock-skills:ask-matt` |
| `superpowers:test-driven-development` | `mattpocock-skills:tdd` |
| `superpowers:systematic-debugging` | `mattpocock-skills:diagnosing-bugs` |
| `superpowers:writing-plans` | `mattpocock-skills:to-spec` |
| `superpowers:brainstorming` | `mattpocock-skills:grilling` |
| `gsd-discuss-phase` | `mattpocock-skills:grilling` |
| `gstack:shape` | `shape` *(kept — no equivalent)* |
| `gstack:clarify` | `clarify` *(kept — no equivalent)* |
| `superpowers:verification-before-completion` | `verification-before-completion` *(kept — no equivalent)* |

The advisor panel no longer shells out to `gstack vote`. It grills the decision
with `mattpocock-skills:grilling`, polls eng via `mattpocock-skills:code-review`,
role-plays the remaining seats inline, and records the result under a
`--- decision-vote ---` commit trailer (was `--- gstack-vote ---`).
`references/gstack-voting.md` is replaced by `references/decision-policy.md`,
which carries the full skill map.

### BREAKING — halt gate measures landed work, not lane occupancy (#8)

The old gate required "no card progressed for 3 ticks" **AND** "no lane active".
Lanes are almost always occupied, so the second clause made the gate
unreachable: one run went 293 ticks over ~6h with zero commits to `main` and
never self-halted. Progress is now a change in the set of cards in
`Done`/`Skipped`, checked every dispatch cycle regardless of lane state.

- New config `no_progress_cycles` (default `6`) — halt after this many cycles
  with nothing landed.
- New config `max_dispatches` (default `0` = unlimited) — hard spend ceiling.
- Both halts print a runaway summary: dispatch count, reap count, cards landed,
  the most re-dispatched issues, and where to find the worker logs.

### Fix: closed issues are no longer re-dispatched (#10)

The loop selected cards by Status column and never checked issue state, so
workers were dispatched at already-CLOSED issues — roughly half of one run's 30
dispatches. Now every dispatch path checks issue state first, and a closed issue
sitting in a non-terminal column is reconciled to `Done` instead of being handed
another worker. Status option IDs for that reconcile are resolved **by name at
runtime** and fail loud on an unknown name, so a column edit can't silently
stale them out.

### Fix: Reviewer merge protocol — Done now means merged (#9)

Builder opens draft PRs and GitHub never auto-merges a draft, so reviewed work
sat on branches: 0 commits to `main` across a 6h window while two complete
builds waited. The Reviewer lifecycle now mandates `gh pr ready` → merge →
**verify the merge commit is an ancestor of the base branch** → only then close
the issue and move the card to Done. A merge-blocked PR routes to `Blocked`
rather than back to `Review`, where it would be re-reviewed indefinitely.
`run-workflow.md` documents the `human_approves_merge` × allowlist matrix that
silently produced the zero-merge night.

### Fix: worker output is captured again (#13)

Workers were spawned with `>/dev/null`, so a 13-minute worker left no trace in
the run log. Output now lands in
`docs/super-board/runs/<date>-<slug>-workers/worker-<lane>-<issue>.log`.
The MSYS-vs-Windows PID namespace trap is documented in the script header —
`kill -0` in Git Bash and PowerShell's `Get-Process` disagree about the same
process, which is what made a live worker look dead during that incident.

### Tests

`tests/test-run-gates.sh` — 28 assertions, deterministic, stubbed `gh`, no
network. Covers the landed-work signal, the halt gate's independence from lane
state, the dispatch ceiling, the closed-issue guard at both the selection and
dispatch choke points, and by-name status-option resolution. `super-board-run.sh`
is now sourceable via `SB_LIB_ONLY=1` for gate testing.

## v1.7.1 — 2026-06-11

### Fix: tolerate JSON-string `args` at wave launch

The Workflow tool can deliver `args` as a JSON-encoded string. The wave script
now normalizes (`JSON.parse` when given a string) before validating, instead of
dying at the args guard. Found live on the magnetgate board.

## v1.7.0 — 2026-06-11

### Model-tier flags for `super-board run`

`super-board run` now takes a model ladder: `--low` (haiku/sonnet/opus by card
complexity), default medium (sonnet/opus/session model), `--high` (opus floor,
session model above). Config key `model_tier` sets the default; the flag wins.
The classify router stays on haiku except on `--high` runs (sonnet). Haiku
never does lane work outside an explicit `--low` run.

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
