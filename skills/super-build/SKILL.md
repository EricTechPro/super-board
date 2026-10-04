---
name: super-build
description: Builder lane of the super-board pipeline — takes a `Ready` GitHub Project card into its own per-issue git worktree, makes the smallest safe change test-first (TDD, `ponytail` simplest-first, official docs first for third-party APIs, upgrades and auth/billing), opens a draft PR and hands it to QA and Review through the board; it never merges — merges go through the Reviewer's merge gate. Inside `super-board run` it runs as a lane agent in the in-session wave workflow (`workflows/super-board-wave.js`, no worker cap unless `max_workers` is set); standalone headless `claude -p` dispatch is legacy opt-in. Use when the user says "Super Build", "run the build loop", "/super-build", or invokes the skill.
---

# Super Build — Builder lane and legacy headless GitHub-Project executor

Inside `super-board run`, Super Build is the Builder lane: a lane agent in the in-session wave workflow (`workflows/super-board-wave.js`) that follows "super-board integration" below. Run on its own, `/super-build` is the **legacy headless path (opt-in)**: you are the orchestrator, the source of truth is the **`Ready` column of the configured GitHub Project board**, and your job is to dispatch every issue in `Ready` (in board order) as a headless `claude -p` worker in its own git worktree, open a PR for each finished branch, and move its card to `QA` so the Tester and Reviewer take it from there. Super Build never merges — merging happens only through the Reviewer's merge gate (`scripts/super-board-merge-gate.sh`).

**Curation contract:** the human moves cards into `Ready` when they should be worked. The loop never reads `Backlog`, `In Progress`, or `Done` cards. If `Ready` is empty, the loop reports "queue empty" and exits cleanly — no error.

**This skill is single-purpose: EXECUTE curated GitHub Project `Ready` issues.** It is INDEPENDENT of `/super-qa` / **Super QA** (the autonomous bug-bash loop that hardens shipped code). They share no state unless a `super-board run` sequences them through the board. Run **Super Build** to make forward progress on the issue queue; run **Super QA** to bug-bash the existing codebase. They CAN run concurrently in different orchestrator sessions, but expect merge conflicts if both touch the same files.

## Role boundary

Super Build is the canonical builder. Do not use a separate `build-feature` workflow. If the user wants a one-off feature, first create or curate a GitHub issue/card with clear acceptance criteria, move it to `Ready`, then let Super Build execute it.

Super Build may implement, test, commit, push, open PRs, and move project cards to `QA`. It never merges, closes issues, or moves cards to `Done` — the Reviewer does that through the merge gate. It should not invent new product scope beyond the issue body. If the issue needs product/design/security judgment, apply the human-gate or WIP-partial path instead of guessing.

**GitHub budget** — every "move card" is `.claude/bin/super-board-card.sh --config <cfg> move <N> <Status>` (1 GraphQL point; `gh project item-list` / `field-list` cost ~100–200). Comments, labels and PR reads go over REST; [rate-limit-etiquette.md](../super-board/references/rate-limit-etiquette.md) → "Price list" has the calls.

## Configuration

The orchestrator needs to know which project board to read.

### Standalone mode (legacy)

Reads `Ready` from the repo's feature project. Resolution order:

1. **`BUILD_LOOP_PROJECT`** env var — project number (e.g. `2`)
2. **`BUILD_LOOP_OWNER`** env var — project owner (e.g. `EricTechPro`)
3. **Auto-discovery fallback:** if env vars unset, run `gh project list --owner $(gh repo view --json owner -q .owner.login) --format json` and pick the project whose `title` matches the repo name, or the only open project if there's exactly one.

Surface: `🎯 Reading project: <owner>/<title> (#<n>), column "Ready"`.

## Algorithm

### 0. Pre-flight

Before reading the board:

- Confirm the main worktree is clean: `git status --porcelain` must be empty.
- Confirm `gh auth status` works and the repo remote points at the expected GitHub repo.
- Confirm `jq`, `git`, and `claude` are available.
- Resolve and print `BUILD_LOOP_OWNER` and `BUILD_LOOP_PROJECT`.
- Run `git fetch origin` and identify the base branch from the current checkout; do **not** assume `main`.

### 1. Read the source column

Source column is `Ready` (override with `BUILD_LOOP_SOURCE_COLUMN`):

```bash
SOURCE_COLUMN="${BUILD_LOOP_SOURCE_COLUMN:-Ready}"

.claude/bin/super-board-card.sh --owner "$BUILD_LOOP_OWNER" --number "$BUILD_LOOP_PROJECT" items \
  | jq --arg col "$SOURCE_COLUMN" '.items[] | select(.status == $col and .content.type == "Issue")'
```

`super-board-card.sh items` is the `gh project item-list` shape for ~1 GraphQL point per 100 cards (item-list spends 101) — without bodies.

For each Ready item:
- Capture `content.number` (issue #), `content.title` and `labels`; read the body over REST: `gh api repos/{owner}/{repo}/issues/<N> --jq .body`.
- **Skip** issues with the `loop:in-progress` label (in flight in another orchestrator) or `loop:halted` label (manually paused) or `human-gated` label (requires manual handling).
- Parse `body` for `Depends on: #N1, #N2` lines (case-insensitive). If any dep is still open AND not in the current Ready set, the issue is blocked — leave it for a future run.
- Parse `body` for an optional `Skills:` line (e.g. `Skills: mattpocock-skills:tdd, verification-before-completion`). If absent, the worker uses defaults from the preamble.

**Ordering:**
1. **Board order first** — `items` returns cards in the human's manual board order. Respect that. If the user wants Issue X before Issue Y, they drag X above Y on the board.
2. **Tiebreaker (rare):** within the same drag-position, sort by priority extracted from title regex `^\[?(P[1-4])\]?`: `P1` < `P2` < `P4` < `P3` < no priority. Then issue number ascending.

If `Ready` is empty: print `📭 Project board "Ready" column is empty — nothing to dispatch.` and exit 0. This is not an error; it means the human hasn't curated work yet.

### 2. Ensure required labels exist (idempotent)

Once per run, before first dispatch:
```bash
gh label create loop:in-progress --color FFA500 --description "Currently being worked on by /super-build" 2>/dev/null || true
gh label create loop:halted --color B60205 --description "Manually paused — /super-build will skip" 2>/dev/null || true
gh label create human-gated --color B60205 --description "Requires manual handling — /super-build will not auto-execute" 2>/dev/null || true
```

### 3. Dispatch wave (worker cap)

Worker cap on this legacy path: `max_workers` from the super-board config when set, otherwise 3.

Report once per wave: `▶️ Super Build dispatching: Issues [#N1, #N2, #N3] (parallel)`

For each issue N in the ready set (up to the cap at a time):

a. **Lock the issue:**
```bash
gh issue edit N --add-label loop:in-progress
```

b. **Announce on the issue** (so a human reading the issue page knows it's being worked):
```bash
gh issue comment N --body "🤖 Dispatched by /super-build — worker spinning up in worktree \`.claude/worktrees/issue-N\` on branch \`loop/issue-N\`. Skills: <skills-line-from-body-or-defaults>."
```

c. **Dispatch:**
```bash
bash .claude/skills/super-build/scripts/super-build-dispatch.sh N
```
…via Bash with `run_in_background: true`. Capture each shell ID.

The dispatcher (this skill's `scripts/super-build-dispatch.sh`) handles:
- `git worktree add -b loop/issue-N .claude/worktrees/issue-N <base-branch>`
- `gh issue view N --json title,body,labels` to compose the worker prompt
- prepend `references/worker-preamble.md` + append working-directory footer
- `cd` into worktree and exec `claude -p --dangerously-skip-permissions --output-format stream-json --verbose --max-turns 250`
- verify the worker produced a `🔧 [chore] loop: close #N` commit on its branch
- exit 0 (success) / 2 (worker non-zero) / 3 (no done-commit) / 4 (HUMAN GATE TRIPPED)

**Base branch:** the orchestrator's currently-checked-out branch (e.g. `frontend-rebuild`). Pass via `BASE_BRANCH` env var to the dispatcher. Don't assume `main`.

### 4. Wait + reconcile

Poll BashOutput on each in-flight shell. As each finishes:

After creating either a complete or partial PR below, follow
[PR author notes](../super-board/references/pr-author-notes.md) before reporting the
handoff complete. Add file summaries and critical inline notes on the PR, not in source.

**On dispatcher exit 0 (success):**
- `git -C .claude/worktrees/issue-N push -u origin loop/issue-N`
- `gh pr create --draft --base <base-branch> --head loop/issue-N --title "<emoji> [<type>] <scope>: <subject>" --body-file <body.md>` — title in commit-subject format, body = the marker-block template from `skills/super-board/references/run.md` (writing-standard.md § 2), `Closes #N` in the status card, `Docs:` bullets in Solution
- `gh issue edit N --remove-label loop:in-progress`
- `gh issue comment N --body "[builder] [report] ✅ built · PR <URL>"` (Next line: `qa`)
- Move the project card to `QA`. The Tester and Reviewer take it from there; the issue closes when the Reviewer merges through the merge gate.
- Leave the worktree in place — the merge gate (after the merge) or the cleanup-wt SessionStart hook removes it once the work is on the base branch.
- Report: `✅ Super Build issue #N → PR <URL>, card in QA`
- Recompute ready set; if new issues are now unblocked, dispatch in the next wave (respecting the worker cap)

**On dispatcher exit 5 (intentional WIP-PARTIAL — open a partial PR, do NOT close):**
- `git -C .claude/worktrees/issue-N push -u origin loop/issue-N`
- `gh pr create --draft --base <base-branch> --head loop/issue-N --title "🚧 [wip] <scope>: <slice from worker's final message>"` — the status card says `Refs #N`, never `Closes`, so the merge does not close the issue.
- `gh issue edit N --remove-label loop:in-progress --add-label human-gated`
- `gh issue comment N --body "[builder] [report] ⚠️ partial · PR <URL>\nDid: <slice>\n❌ Not done: <worker's reason for stopping>\nNext: Eric"` — the issue stays open with `human-gated` until the rest lands.
- Report: `🟡 Issue #N partial PR opened — issue stays open (human-gated)`
- **Continue dispatching the next issue in the wave.** A WIP-PARTIAL is NOT a halt. The worker did intentional, scoped work and the orchestrator advances.

**On dispatcher exit 2 or 3 (worker failed or no done-commit):**
- `gh issue edit N --remove-label loop:in-progress`
- `gh issue comment N --body "[builder] [report] ❌ failed · exit <X>\nDid: worker ran; worktree \`.claude/worktrees/issue-N\` kept\n❌ Not done: <one line from the log>\nNext: Eric\n\n<details><summary>log tail</summary>\n\n\`\`\`\n$(tail -50 .planning/super-build-logs/issue-N.log)\n\`\`\`\n</details>"`
- Report to the user with `tail -50` of `.planning/super-build-logs/issue-N.log`
- Do NOT open a PR; leave the worktree intact for human inspection
- Halt the loop

**On dispatcher exit 4 (HUMAN GATE TRIPPED):**
- `gh issue edit N --remove-label loop:in-progress --add-label human-gated`
- `gh issue comment N --body "🔴 HUMAN GATE TRIPPED — needs manual handling. See worktree \`.claude/worktrees/issue-N\`."`
- Report: `🔴 Issue #N tripped HUMAN GATE — needs manual handling`
- Halt the loop

### 5. Final report

When the selected GitHub Project `Ready` queue is empty, or only blocked cards remain: report a summary listing PRs opened this run (cards in `QA`), issues not built (`human-gated` / `loop:halted` / blocked dependencies), and any halts. Suggest: "Run `super-board run` to test, review and merge them."

## Issue contract

Every Ready issue should be executable without live clarification. Preferred issue body shape:

```markdown
## Goal
<one-sentence outcome>

## Acceptance Criteria
- [ ] <observable behavior or artifact>
- [ ] <test/verification expectation>

## Notes / Constraints
- Depends on: #123, #456
- Skills: mattpocock-skills:tdd, verification-before-completion
- Human gates: <deploy, destructive DB action, product decision, etc.>
```

Super Build treats acceptance criteria as the completion contract. Workers must not edit checkboxes to make the issue look complete. If the issue is too vague to execute, label/comment it as human-gated instead of guessing.

## Constraints

- **Worker cap:** `max_workers` from the config when set, otherwise 3 on this legacy path (resource throttle). The workflow backend has no cap unless `max_workers` is set.
- **Never auto-touch issues with `human-gated` label** (production cutover, secrets, irreversible ops).
- **Never modify code in the main worktree** while workers are running. Only run `gh` commands and push/PR operations.
- **Conflicts** between concurrent workers' branches are not resolved here — they surface at the merge gate, and the card comes back to the Builder for a rebuild. Don't auto-resolve.
- **Report cadence** (to the user, in the session): 1 message at start, 1 per dispatch wave, 1 per completion (success/fail), 1 final summary. Don't spam.
- **Workers MUST use the right skills.** The worker preamble enforces: workers parse the `Skills:` line from the issue body if present; otherwise they route on the issue's **type label** (`bug` → `diagnosing-bugs`+`tdd`, `feature` → `implement`+`tdd`+`codebase-design`, `refactor`/`tech-debt` → `codebase-design`+`tdd`, `docs` → skip `tdd`), always adding `ponytail:ponytail` (simplest solution first, before any code; inline fallback when the plugin is absent), `verification-before-completion` and a `code-review` pass on their own diff. Test mechanics are picked by the localisation ladder, never by label. Decision points walk the decision ladder — acceptance criteria → repo precedent → smallest blast radius → human gate — and stop at the first rung that answers the question. No panel, no vote; `mattpocock-skills:grilling` is forbidden inside a worker (it waits on a user who is not there) and lives in `super-board lint` instead. `mattpocock-skills:code-review` runs once against the worker's own diff before the final commit. See `references/decision-policy.md` for the skill map, the ladder, the human gates, and the `--- decision ---` commit trailer.

## Worker preamble

The preamble at `references/worker-preamble.md` is the worker contract: decision policy, HUMAN GATE handling, the per-issue 14-gate contract, and final-commit format. The dispatcher prepends it to every worker prompt. See that file for the verbatim text.

## Recovery / re-entry

If the user invokes `/super-build` after a partial run:
- Re-read `gh issue list`. Issues already closed are skipped automatically.
- If legacy `.worktrees/issue-N` exists, stop and inspect it before dispatch. Preserve edits and use `git worktree move` to the matching `.claude/worktrees/issue-N` path; never delete the old folder to make a fresh dispatch fit.
- If `.claude/worktrees/issue-N` exists for an N that's still open: a previous worker was interrupted. Default: notify the user and ask before auto-resuming (a re-dispatch overwrites the previous attempt's branch).
- If the `loop:in-progress` label is set on issue N but no worktree exists: stale lock from a crashed orchestrator. Remove the label and treat as ready.

## Stop conditions

- Selected GitHub Project `Ready` queue is empty, or all remaining Ready cards are blocked / `human-gated` / `loop:halted`.
- Any worker fails (dispatcher exit 2 or 3).
- HUMAN GATE TRIPPED (dispatcher exit 4).
- Push or PR creation fails.
- User interrupts.

**Not a stop condition:** WIP-PARTIAL (dispatcher exit 5). The orchestrator opens a partial PR, leaves the issue open with `human-gated`, and continues dispatching the next issue in the wave. WIP-PARTIAL is intentional, bounded work.

## Invocation patterns

- `Super Build` / `/super-build` → process all GitHub Project `Ready` issues in board order
- `/super-build --only N` → execute only issue #N (smoke-test mode, ignores `loop:in-progress` label on that issue if you set `FORCE=1`)
- `/super-build --dry-run` → print the dispatch plan (issues, order, parallelism waves) without invoking workers, without setting labels, without commenting

## Companion skill

`/super-qa` / **Super QA** is the autonomous bug-bash iteration loop. It is **independent of this skill** unless a `super-board run` sequences them through the board. Run **Super Build** for forward progress on Ready issues; run **Super QA** to harden the existing codebase by hunting bugs.

## super-board integration

When invoked by super-board (env `SUPER_BOARD_RUN=1` set by the runner, or invocation contains "super-board run"), follow these rules instead of the standalone defaults:

### State protocol
- Read context from: issue body + ALL issue comments + linked PR description + PR comments + PR review threads. NEVER from local state files for inter-lane coordination.
- Respect the worktree path super-board hands you (typically `.claude/worktrees/issue-<N>-build/`). Don't create your own.
- Respect the single branch super-board hands you (`issue-<N>-<slug>`). Don't create alternate branches.

### Lifecycle (Builder, first pass)
Follow spec `.claude/skills/super-board/references/run.md` → Builder (first pass). Summary:
1. Worktree off `config.base_branch`.
2. Branch `issue-<N>-<slug>` from `config.base_branch`.
3. Docs check (section below) — if the ticket touches a third-party surface, an upgrade, or auth/billing, read the current official docs first.
4. Implement smallest safe change covering ACs — under the PR size cap (section below).
5. Commit + push (always).
6. Open **draft PR** with the PR description template from `run.md` — title in commit-subject format, every marker block filled, `Docs:` bullets in Solution.
7. Follow [PR author notes](../super-board/references/pr-author-notes.md), then post the `[builder] [report]` PR comment + the short issue comment with the PR URL (writing-standard.md § 4).
8. Move card Ready/Building → QA.

### Keep each PR small (every ticket)
Each PR stays under the merge size cap: `merge_policy.auto_max_lines` (default 400 changed lines,
additions + deletions; lockfiles, generated files, snapshots and migration SQL do not count — see
`merge_policy.size_exclude`). A PR over the cap is never auto-merged: the merge gate parks it in
Blocked 🙋 "big PR — please review".

Check `git diff --shortstat origin/<base>...HEAD` (minus excluded files) before each push. If the
change grows past the cap mid-build, **stop — do not push on**. Commit and push what you have on
the branch, leave the PR as a draft, and post a PR comment proposing the split: the vertical
slices (each thin end to end, under the cap, with its own ACs), which slice this PR keeps, and
`/to-tickets` as the way to file the rest. Then move the card to Blocked with `❓` ("too big —
split proposed in PR #<P>", `block-template.md`). Never pad past the cap to "finish" the ticket.

### Lifecycle (Builder, rebuild)
Triggered when card returns to Ready/Building with `loop:rebuild-N` label.
1. Read PR review threads on this branch's PR; filter `[builder]` prefix.
2. For each unresolved `[builder]` thread: read file:line + suggested fix → apply → resolve thread via:
   ```bash
   gh api graphql -f query='mutation($threadId:ID!){resolveReviewThread(input:{threadId:$threadId}){thread{isResolved}}}' -f threadId="<thread-id>"
   ```
3. Address any new failure feedback from Tester's latest ❌ comment.
4. Commit + push to same branch. Verify ALL `[builder]` threads are resolved before exit.
5. Refresh [PR author notes](../super-board/references/pr-author-notes.md), rewrite your PR body blocks (`super-board-pr-body.sh`), post `[builder] [report]` PR + issue comments. Move card Ready/Building → QA.

### Docs before outside-tool code (every ticket)
Before writing code, decide whether the ticket touches any of:
- a third-party API, SDK, library, CLI or cloud service (calling it, configuring it, adding it);
- a dependency or framework **upgrade**;
- **auth or billing** (OAuth/scopes, sessions, tokens, webhooks, payments, plans).

If yes, read the **current official docs** for the exact surface and version first — context7
when available, otherwise web search to the vendor's own docs, migration guide or changelog.
Check the installed version (`package.json` / lockfile, `npm view <pkg> version` for a new dep)
and read the docs for that major. Repo docs and existing call sites come first for how *this*
repo uses it; vendor docs settle what the tool does. Not Stack Overflow, not old blog posts,
not memory.

Cite what you read as `Docs:` bullets at the end of the PR body's Solution block (URL + the one
fact it settled). Docs unreachable → say so there and in the `[builder] [report]` comment, mark the
affected code `unverified against current docs`, and keep the change minimal. No outside tool
touched → `Docs: none needed — no third-party surface`.

### Failure → handoff comment must include `root-cause-hash:` line
On any failure-handoff comment, include:
```
root-cause-hash: <sha256 first 12 hex chars>
```
Hash inputs (joined with `|`): lane (`build`) | error class | first 3 unique normalized file:line frames. See `.claude/skills/super-board/references/run.md` → Root-cause hash.

### Never merge
Builder NEVER squash-merges. Reviewer owns merge.

### Block exits use the §4 mandatory template
When moving a card to Blocked (or dropping it: closed as not planned, Done, 🤷), populate the full template from `.claude/skills/super-board/references/block-template.md`. A 1-line "needs creds" comment is a contract violation.
