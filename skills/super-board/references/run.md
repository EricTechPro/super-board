# super-board run — full contract

**Scope:** the lane lifecycles (Builder, Tester, Reviewer) that both backends use, and the legacy `claude-p` runner (`worker_backend: "claude-p"`). The default in-session wave loop is in `run-workflow.md`.

**Where the legacy runner runs:** headless. Spawned as a `nohup`-backgrounded process; the current Claude session exits immediately after dispatch. The runner script (`scripts/super-board-run.sh`) is a pure shell while-loop that dispatches one `claude -p` worker per lane and never holds Claude session state. Each `claude -p` worker is its own short-lived headless context — load this file at the start of every lane.

## Required GitHub reads can pause a run

Use `.claude/bin/super-board-github-read.py` for required API evidence. It retries
one failed read at most twice (three total attempts); invalid queries or missing
authority halt immediately. Exit **79** means stop dispatch and pause the current
run. Never substitute an empty board, OPEN issue, full quota, or empty diff.
Check the helper's `--check` before each write, migration, or merge. Preserve
worktrees, claims, card/approval state, and the shared local halt record. Report
the reason locally when GitHub cannot accept a comment. Do not blindly retry a
mutation: a lost response may conceal a successful write. Confirm its remote
outcome once service is available before resuming. Recovery and workflow
checkpoint limitations: [run-workflow.md](run-workflow.md#required-github-evidence-and-a-paused-run).

## Orchestrator delegation contract (NON-NEGOTIABLE)

**Super-board is an autonomous trader. The interactive Claude session that invokes `super-board run` is an orchestrator, NOT a worker.** Its only jobs are:

1. Verify preconditions (see table below).
2. Spawn the headless `nohup ./scripts/super-board-run.sh <slug> &` runner.
3. Report runner PID + log path back to the user.
4. Exit.

The orchestrator MUST NOT:

- Build, test, review, or fix issues itself. All product work is delegated to `claude -p` workers via `dispatch_lane`.
- Patch the dispatcher script or skill files unless the user explicitly asked for that change. Drift fixes belong in a follow-up issue, not a side-edit during a run dispatch.
- Wait for workers to finish. Workers run in their own contexts and write evidence back to the issue + PR. The orchestrator's output to the user is the dispatch confirmation, not the run result.
- Hold context for multi-card progress. Workers own the state machine via the GitHub Project board + assignee mutex + inflight lock files.

If a problem surfaces during the run (bug in the dispatcher, missing skill, stuck card), the orchestrator should: (a) capture the symptom, (b) tell the user what they observed, (c) wait for explicit approval before touching anything. **Do not silently expand the task into "fix the dispatcher while you're at it" — that's the orchestrator becoming a worker.**

When the user asks for diagnostics or a fix, prefer dispatching a focused `claude -p` worker (or named subagent) over doing the work in the orchestrator session, so the orchestrator's context stays small and the work stays inspectable in its own log.

## Intro shown when run starts

```
🤖 super-board run
─────────────────────────────────────────────────────────
Purpose: the autonomous loop. Drains your GitHub Project board.

Progress: ✅ onboard  →  ✅ lint  →  🤖 run (you are here)
─────────────────────────────────────────────────────────
```

## Preconditions (verified before any worker dispatches)

| Check | Action on fail |
|---|---|
| Active config exists | Halt: "Run `super-board onboard` first." |
| Project + required columns exist | Halt: "Project / columns missing. Run `super-board onboard` to repair." |
| `gh auth` valid with required scopes | Halt: "Re-auth: `gh auth refresh -s project,read:project,repo`." |
| `pre-flight.md` all items `[✓]` | Halt: "Pre-flight incomplete — fix these: [list]." |
| No issues missing ACs in active columns | Halt: "N issues need clarification. Run `super-board lint`." |
| Clean git working tree on base branch | Halt: "Working tree dirty. Stash or commit before running." |
| Legacy worktrees | If `.worktrees/issue-*` exists, halt before dispatch. Stop its worker, inspect/preserve edits, then `git worktree move` it to the matching `.claude/worktrees/` path. Never delete it as part of an upgrade. |
| Stale worktree scan | Scan only `.claude/worktrees/issue-<N>` and `issue-<N>-build/qa/review`. If its named branch is gone, use `git worktree remove` without force. Keep detached, dirty, locked, unregistered, or unrelated folders; log failures for inspection. A missing board label alone is not permission to delete work. |
| Production-merge guard | If `base_branch == "main"` AND `human_approves_merge == false` AND `merge_policy.default != "human"` AND `merge_policy.allow_auto_on_production != true` AND production-detection signals fire (see onboard → base branch), halt with: `🛡 Refusing to start: would auto-merge to production main. Set merge_policy.default: "human", switch base_branch to staging, or re-run super-board onboard to opt in explicitly.` |
| Orphan-worker scan (added 2026-05-22 after #381 worker storm) | `pgrep -f 'claude -p .*super-board run'` must return zero. If any super-board worker is already alive from a prior crashed run, halt with: `🛑 ${N} super-board workers already running. Stop them first: pkill -f 'claude -p .*super-board run'`. The dispatcher must never run while orphan workers exist — they will collide on assignee claims and produce duplicate PRs. |
| Database reach | Run every `migrations.checks[env]` for an env in `allowed_envs` (read-only, e.g. `supabase migration list --db-url …`). On failure halt with its error: "Migrate URL for <env> does not connect — fix it before a wave builds work the gate cannot land." |
| GraphQL rate-limit guard | Before each tick, `sb_gh_guard_check` (super-board-gh-guard.sh — it reads GraphQL's own `rateLimit`, because `gh api rate_limit` misreports the GraphQL bucket). If GraphQL remaining < 200, sleep until reset. Prevents the runner from dying mid-loop when the user has burned quota in another tool. |

## Lanes and label routing

One board shape (v3.0.0): Backlog · Ready · Building · QA · Review · Blocked · Done. A card's
label picks its path — three labels, no per-board variant:

| Label | Path | Why |
|---|---|---|
| `feature` | Ready → Building → QA → Review → Done | new behaviour: build, test, review |
| `bug` | Ready → Building → QA → Review → Done | a fix: same lanes |
| `qa` | Ready → QA → Review → Done | test what already exists; skips Building |
| none | as `feature` | the classifier adds `feature` or `bug`; it never adds `qa` |

`super-board-wave-plan.sh` puts `lane` (`build` / `qa` / `review`) and `labels` on every picked
card; `super-board-wave.js` sends a `qa` card from Ready straight to the Tester. The legacy runner
reads the label of the top Ready card the same way (`card_lane`).

```
Builder:   Ready → Building → QA
           worker   = super-build skill
           worktree = .claude/worktrees/issue-<N>-build/
           branch   = issue-<N>-<slug>  (created here, persists across lanes)

Tester:    QA → Review            (a `qa` card: Ready → QA → Review)
           worker   = super-qa skill (issue-scoped mode)
           worktree = .claude/worktrees/issue-<N>-qa/
           branch   = same issue-<N>-<slug>  (a `qa` card: the Tester creates it)

Reviewer:  Review → Done
           worker   = super-review skill
           worktree = .claude/worktrees/issue-<N>-review/
           branch   = same issue-<N>-<slug>  (squash-merged on approval)
```

**`qa` cards.** The Tester moves the card Ready → QA itself, creates `issue-<N>-<slug>` from the
base branch, and tests what is already there against the ACs. Tests it writes are committed to
that branch; a PR opens only when there is something to merge (tests, evidence). A failure it
cannot fix with tests alone is filed as a `bug` card (`super-qa-file-bug.sh`) and named in the
handoff — the `qa` card still moves on to Review with the findings. The Reviewer reviews the QA
report and any test diff.

A live site with no repo is not a board. `/super-qa <url>` tests it on its own.

## Dispatch allocation model — one worker per lane, not per backlog

`super-board run` allocates headless Claude capacity by **lane**, not by how many cards are stacked in one column.

- **Max concurrency:** 3 workers total — at most one Builder, one Tester, and one Reviewer at the same time.
- **Never dispatch multiple workers from the same column just because that column has a backlog.** If all cards are in `Ready`, the runner dispatches exactly one worker for the top card — a Builder, or a Tester when the card is labelled `qa` — until it exits.
- **Mixed-column example:** if `Ready`, `QA`, and `Review` each contain cards and all lanes are idle, the runner dispatches three workers: one Builder from `Ready`, one Tester from `QA`, and one Reviewer from `Review`.
- **Downstream-first priority:** when multiple lanes are available, dispatch Review before QA before Ready/Build, so finished work gets closed before new build work starts.
- **Lane idle gate:** a lane is eligible only when its prior worker process has exited. The runner must track lane PIDs or an equivalent lane lease; GitHub issue assignees are per-card mutexes, not lane-capacity controls.

This means a board with 30 cards in `Ready` and zero elsewhere does **not** start 3 Builder sessions. It starts one Builder. As that Builder moves its card to `QA` and exits, the next tick can start one new Builder for the next `Ready` card and one Tester for the first `QA` card, because those are different lanes.

## Branch + PR model — one branch, one PR per issue

Format: **`issue-<N>-<kebab-title>`** (no lane prefix).

Example: `issue-42-add-chat-streaming`.

There is **exactly one branch per issue** and **exactly one PR per issue**. All three lanes work on the same branch in their own worktrees:

- Builder creates the branch off `config.base_branch`, writes code, commits + pushes, opens a **draft PR**.
- Tester checks out the same branch in a fresh worktree, adds tests, commits to the same branch, pushes.
- Reviewer is the **only lane that merges**. On approval: squash-merges PR into `base_branch`, deletes the branch.
- If `config.merge_policy` says a human merges (`default: "human"`, or a money / auth / schema / size hit), the merge gate exits 7 and the Reviewer parks the card in Blocked for a human click instead.

## PR description template

Format: `writing-standard.md` § 2. Title = the commit subject format
(`✨ [feat] chat: stream replies`). The body is marker blocks; each lane rewrites only its own
with `.claude/bin/super-board-pr-body.sh --pr <P> --block <name> --expect-head <sha>
(--body-file | --append-file) <md>`. The script refuses (exit 6) when the PR head moved since you
read it — re-read, then redo the edit. Builder opens the PR with every block filled
(`super-board-pr-body.sh --skeleton` prints the empty markers).

| Block | Builder | Tester | Reviewer |
|---|---|---|---|
| `status` (alert card) | writes | rewrites on exit | rewrites on exit |
| `problem` (lettered steps under Where, screenshot embedded) | writes from the ticket's Context | — | — |
| `solution` (plain bullets, `Docs:` bullets last) | writes, updates on rebuild | — | — |
| `ac` (checklist + one proof line each) | writes all unchecked | ticks with proof, or leaves unchecked with the reason | unticks one it disproved |
| `history` (Lane · Done · Time · Details) | appends a row | appends a row | appends a row |
| `visual` (Before \| After, UI only) | — | writes | — |
| `risk` (🟢/🟡/🔴 + one line) | writes | — | adjusts |
| `redcheck` (only when merged with a failing check) | — | — | writes |

```markdown
<!-- sb:status -->
> [!NOTE]
> ⏳ In QA · round 1 · ✅ 0/2 AC · Closes #<N> · head `<sha>`
<!-- /sb:status -->

<!-- sb:problem -->
## Problem
- **Where:** <page>, `<route>`
  - a. <step>
  - b. <step>
- **Who:** <who sees it>
- **What happened:** <one line>

![<page> · desktop](https://github.com/<OWNER>/<REPO>/raw/<sha>/<path>.png)
<!-- /sb:problem -->

<!-- sb:solution -->
## Solution
- <one change per bullet>
- Docs: <url> — <the one fact it settled>   (or: Docs: none needed — no third-party surface)
<!-- /sb:solution -->

<!-- sb:ac -->
## Acceptance criteria
- [ ] <AC1 text>\
  ↳ not verified yet: QA has not run
- [ ] <AC2 text>\
  ↳ not verified yet: QA has not run
<!-- /sb:ac -->

<!-- sb:history -->
## Iteration history
| Lane | Done | Time | Details |
|---|---|---|---|
| 🔨 builder | ✅ | <super-board-pr-body.sh --time> | draft · `<sha>` |
<!-- /sb:history -->

<!-- sb:risk -->
## Risk
🟢 **Low** · <one line: what could break and what limits it>
<!-- /sb:risk -->
```

History rows by lane: `🔨 builder` · `🔍 qa` (`❌ v1` / `✅ v2`, details = evidence folder) ·
`🧐 reviewer` (`❌ bounced` / `✅ merged`, details = finding ids or `squash <sha>`). Time comes
from `super-board-pr-body.sh --time --config <cfg>` (config `timezone`).

Status card lines: `> [!NOTE]` + `🔨 Building` / `⏳ In QA` / `⏳ In review · round N` ·
`> [!TIP]` + `✅ Merged · <sha>` · `> [!WARNING]` + `🛑 Blocked · <reason>`. Each names the AC
count and the head commit, so evidence is never read against a different one.

No "Not verified" and no "Next" section: an unchecked AC with its one-line reason says what is
not proven. Merged with a failing check (the 💳 CI-budget bypass) → the Reviewer writes the
`redcheck` block first:
`> [!WARNING]` / `> 🔴 Merged with a failing check: <check> · <why it was safe>`, and names the
check in `risk` too.

## PR review-comment threads — prefix + resolution protocol

Reviewer findings use **line-level review comments** (resolvable threads). Each finding MUST start with the lane that owns the fix — `[builder]`, `[qa]` or `[reviewer]` — then a label (`[blocker]`, `[issue]`, `[suggestion]`, `[nit]`, `[question]`, `[praise]`; writing-standard.md § 4). Read `[QA]` and `[review]` on older PRs as `[qa]` and `[reviewer]`. [PR author notes](pr-author-notes.md) have their own format; read all replies before treating a thread as explanation only.

Examples:

```
src/api/stream.ts:54   [builder] [blocker] uses `new Date()` — replace with `clock.now()`.
e2e/streaming/ttfb.spec.ts:18   [qa] [issue] spec asserts status only — add a TTFB assertion.
```

**Resolution rules (each lane only scans the current branch's PR):**

| Lane exiting | Must resolve | Refusal action |
|---|---|---|
| Builder (Building → QA) | All `[builder]` threads on this PR | Stay in Building, fix, then exit |
| Tester (QA → Review) | All `[qa]` threads on this PR | Stay in QA, fix, then exit |
| Reviewer (approving merge) | All findings and human requests; any conversations GitHub requires resolved | Bounce: `[builder]` open → Ready; `[qa]` open → QA; unresolved human decision → Blocked |

Threads are resolved via `gh api graphql` `resolveReviewThread` mutation when the fix is committed.

## Lane lifecycles (per card)

### Builder pre-flight (before ANY card goes Ready → Building)

Two agents must never build the same thing, and nothing already on the base branch gets built
twice. So before a Builder starts, a **fresh, cheap sub-agent** (no code, no worktree) checks the
card. Workflow backend: the wave's `Pre-flight` phase does it, one agent per batch of up to 5 Ready
cards, before `runLane('build')`. Legacy `claude-p` backend: the Builder runs it as step 0 below,
in a sub-agent, before touching a worktree.

```
[ ] source .claude/bin/super-board-gh-guard.sh; sb_gh_guard_check 200
[ ] build the in-flight list: .claude/bin/super-board-card.sh --config <cfg> items (one call) → [{number,title,status}] for
    Building / QA / Review / Ready cards; save it to a temp file
[ ] bash .claude/bin/super-board-preflight.sh --repo <owner/name> --issues <N[,M…]> \
         --inflight <file> [--files <paths you expect to touch>]
[ ] judge each card: the script's verdict, then its `candidates` (near-misses) semantically
[ ] act on the outcome below, then return one verdict per card
```

The script asks four questions and the agent adds a fifth; the agent owns the judgement:

| # | Question | Mechanical signal (script) | Agent adds |
|---|---|---|---|
| 1 | Already done? | merged PR closes `#N`; merged PR / closed issue with the same `fingerprint:` or title | a merged PR that delivers the same behaviour under other words |
| 2 | Already in progress? | open PR on another branch closes `#N` or has the same title; a card in Building/QA/Review (or a lower-numbered Ready peer) with the same title | same feature, different words — not merely the same files |
| 3 | File overlap? | open PR touches files the card names; a lower-numbered card in the same `--issues` batch names the same files | expected files from reading the issue (`--files`); the same overlap with a Ready peer in another batch |
| 4 | Unclear? | no `## Acceptance Criteria` bullets | AC that contradicts the current code (cite `file:line`) |
| 5 | Too big? | — | likely over ~400 changed lines (`merge_policy.auto_max_lines`; lockfiles, generated, snapshots, migration SQL excluded) or spans many areas (UI + API + DB + jobs …) — lint.md criterion 15 |

**Two Ready cards that overlap each other, neither with an open PR, go one at a time.** The
lower-numbered card proceeds; only the other is sequenced, with `blocked-by: #<lower>`, and the
wave-start sweep frees it once the lower one closes. Sequencing each against the other leaves
both with nothing to wait on and neither built — the same deadlock comes back every wave.

The agent may turn a `proceed` into a `hold` on evidence. It may turn a mechanical `hold` into
`proceed` only by naming why the match is a different feature. Its own branch's PR
(`issue-<N>-*`) is the card coming back, never its own duplicate.

**Outcomes — never drop a card silently:**

| Verdict | Action | Block template (`block-template.md`) |
|---|---|---|
| `proceed` | nothing; the Builder starts | — |
| `hold` — done | move card to Blocked | `👯` · names the merged PR / closed issue · Owner: Eric (close as duplicate) · `blocked-by: -` |
| `hold` — in progress | move card to Blocked | `👯` · names the open PR / card · `blocked-by: <the issue that PR or card closes>` — the sweep returns it when that closes, and pre-flight then finds it done |
| `hold` — unclear | move card to Blocked | `❓` · the missing AC or the contradiction with `file:line` · `blocked-by: -` |
| `hold` — too big | move card to Blocked | `❓` · "too big — likely over <cap> changed lines / spans <areas>" · suggests splitting with `/to-tickets` into vertical slices, each under the cap · `blocked-by: -` |
| `sequence` — `blockedBy` non-empty | move card to Blocked | `⏳` · the overlapping PR and files · `blocked-by: <blockedBy>` — the wave-start sweep frees it |
| `sequence` — `blockedBy` empty | proceed (card stays Ready, return column `Ready`), comment `⚠️ expected conflict with PR #<P> on <files> — the merge gate will rebase` | — |
| `halted` | script exit 79: required evidence unavailable; leave the card untouched, stop this run, resume explicitly after recovery | — |

A card the pre-flight agent returns no verdict for is treated as `skipped` (a verdict, not a
column), never built unchecked. `qa` cards are not pre-flighted: nothing is built.

### Builder (first pass)

0. Legacy backend only: run the Builder pre-flight above in a sub-agent. Anything but `proceed`
   (or a conflict-note `sequence`) → do what its row says, release the claim, exit.
1. Create worktree `.claude/worktrees/issue-<N>-build/` off `config.base_branch`.
2. Create branch `issue-<N>-<slug>` from `config.base_branch` — unless one already exists
   (the card came back from Building after a stopped run): then check it out, keep its
   commits and open PR, and continue from where it stopped.
3. Read issue body + ALL comments + PROJECT.md.
3b. Touches a third-party API/SDK, an upgrade, or auth/billing? Read the current official docs
    for the installed version first (super-build → "Docs before outside-tool code").
4. Implement smallest safe change covering ACs, under the PR size cap
   (`merge_policy.auto_max_lines`, default 400 changed lines). Growing past it mid-build → stop,
   push what you have, propose the split (vertical slices via `/to-tickets`) in a PR comment and
   move the card to Blocked `❓` — never push on past the cap (super-build → "Keep each PR small").
5. Commit + push (always). Commits follow writing-standard.md § 1 (`✨ [feat] chat: stream replies` + short bullets).
6. Open draft PR linked to the issue with the PR description template (title in commit-subject format, every block filled).
7. Follow [PR author notes](pr-author-notes.md), then post the `[builder] [report]` PR comment (see "Commenting cadence").
8. Post a short status comment on the issue with the PR URL.
9. Clean up worktree. Keep branch + PR open.
10. Move card Building → QA.

### Builder (rebuild)

1. Worktree as above.
2. Read PR review threads on this branch's PR; filter `[builder]` prefix.
3. For each unresolved `[builder]` thread: read file:line + suggested fix, apply, resolve thread via graphql mutation.
4. Address any new failure feedback from Tester's latest `❌` comment.
   (A Reviewer bounce reaches you as those same `[builder]` threads, listed in the latest `<!-- super-review:report -->` comment. A finding the Reviewer re-opened as `not fixed` was resolved without a fix last time — fix the code, not just the thread.)
5. Commit + push to same branch.
6. Verify ALL `[builder]` threads are resolved. If not, return to step 3.
7. Refresh [PR author notes](pr-author-notes.md), rewrite `status`, `solution`, `history` blocks; post `[builder] [report]` PR + issue comments. Move Building → QA. Clean up worktree.

### Tester (first pass — repo-backed)

1. Pull latest of base; checkout `issue-<N>-<slug>` into worktree `.claude/worktrees/issue-<N>-qa/`.
   A `qa` card has no branch yet: move it Ready → QA, then create the branch from the base.
2. `target.url` set → health-check it first. Unhealthy → Block.
3. Read issue + PR + Builder's handoff comment.
4. Build issue-scoped test plan: one observable test per AC.
4b. **Test-gap check** (super-qa → "Test-gap check (after build)"): map every AC to unit / component / e2e tests, hunt edge cases, write the High gaps red-first. A High gap that needs app code changed → Fail (step 7) with the gap list. Medium/Low go in the handoff under `Test gaps (not written)`.
5. Run the tests. Capture evidence to `docs/super-board/runs/issue-<N>-qa-v<N>/`. For UI/visual ACs, capture screenshots at the standard viewports (1920×1080 desktop, 1024×768 tablet, 375×667 mobile). Commit the screenshots to the issue branch BEFORE writing the comment (the markdown image URLs depend on the files being present on the branch).
6. **Pass** → commit test files + screenshots to same branch + push → tick the `ac` block with proof lines, write `visual` for UI, append a `history` row, rewrite `status` → `[qa] [report] ✅` PR comment with results + evidence path **+ inline screenshot embeds** (see "Screenshot embed format" below) → issue comment with the SAME inline screenshot embeds → move card QA → Review. Clean up worktree.
7. **Fail** → leave failing ACs unchecked with the reason, append a `history` row, rewrite `status` → `[qa] [report] ❌` PR comment with per-AC expected/actual + repro file:line + evidence path + "what fixed should look like" **+ inline screenshot embeds of the broken state** → issue comment with the same inline screenshots (showing what's wrong) → increment rebuild counter → move card QA → Ready (label `loop:rebuild-N`). Clean up worktree.

#### Screenshot embed format (mandatory on every QA exit — added 2026-05-22)

Inline screenshots in the GitHub comment using raw-URL markdown so they render directly on the issue/PR page without anyone having to clone the repo:

```markdown
| Viewport | Screenshot |
|---|---|
| Desktop 1920×1080 | ![desktop](https://github.com/<OWNER>/<REPO>/raw/<SHA>/docs/super-board/runs/issue-<N>-qa-v<V>/desktop.png) |
| Tablet 1024×768  | ![tablet](https://github.com/<OWNER>/<REPO>/raw/<SHA>/docs/super-board/runs/issue-<N>-qa-v<V>/tablet.png) |
| Mobile 375×667   | ![mobile](https://github.com/<OWNER>/<REPO>/raw/<SHA>/docs/super-board/runs/issue-<N>-qa-v<V>/mobile.png) |
```

Substitution rules:
- `<OWNER>/<REPO>` — read from `git remote get-url origin` (parse owner/name).
- `<SHA>` — the commit that added the screenshots (`git rev-parse HEAD` right after committing them), never a branch name: the branch is deleted on merge and a branch URL breaks. Push before you post.
- `<N>` and `<V>` — issue number + QA version (`v1`, `v2`, ...).
- File names — keep them stable and descriptive (`desktop.png`, `tablet.png`, `mobile.png`, or `before-fix-desktop.png` / `after-fix-desktop.png` for rebuild-pass cases).

For non-visual ACs (API tests, migration SQL, etc.), skip the screenshot block but keep the evidence-path line. Tests output (logs, REPORT.md) still goes in the evidence folder.

If a screenshot file is >5MB, downscale to ≤1920px wide before committing; GitHub's image rendering chokes on huge images.

### Tester (rebuild — when Reviewer bounced for `[qa]` thread fixes)

1. Worktree as above.
2. Read PR review threads; filter `[qa]` prefix.
3. For each unresolved `[qa]` thread: apply fix to test files, resolve thread.
4. Re-run full test suite for the ticket.
5. Save evidence to `runs/issue-<N>-qa-v<N+1>/`.
6. Commit + push. Verify ALL `[qa]` threads are resolved.
7. Update `ac`, `history`, `status`; post `[qa] [report]` PR + issue comments. Move QA → Review. Clean up worktree.

### Reviewer

1. Worktree `.claude/worktrees/issue-<N>-review/` from current state of `issue-<N>-<slug>`.
2. **Gate 1** — scan PR threads and their replies. [PR author notes](pr-author-notes.md)
   alone are explanations, not findings. Human questions or change requests in those
   threads still follow the normal review/blocking flow; the marker exempts no replies.
   Never auto-resolve them or bypass GitHub's conversation-resolution requirements.
   If ANY unresolved finding:
   - `[builder]` open → comment, move card Review → Ready.
   - `[qa]` open → comment, move card Review → QA.
   - Both open → bounce to whichever is older; the other gets picked up later.
   - Clean up worktree, exit.
3. Read the issue ACs and the raw diff (code + test files) FIRST and write 2–4 hypotheses of your own — what must hold, where it would break. Only then read the PR description, the `[builder] [report]` comment and Tester's handoff, and check each claim like a hypothesis. Spot-check Tester's evidence (one screenshot at least), read CLAUDE.md / AGENTS.md.
3b. **Prior-report check (review remembers — added 2.5.0).** Load the last Reviewer report on this PR as `prior_report`. One call:
   ```
   gh pr view <PR> --json comments \
     --jq '[.comments[] | select(.body | contains("<!-- super-review:report -->"))] | last | {url, body} // {}'
   ```
   - Empty → first review of this card. Skip to step 4; behave exactly as before.
   - Non-empty → the card was bounced and rebuilt. **Round 1** walks every finding in `prior_report` and marks each one `fixed` / `not fixed` / `no longer applies` (code it pointed at is gone or the AC changed), citing the file:line that proves it. A resolved thread is not proof — check the code.
   - Any `not fixed` → bounce again now: re-open one thread per unfixed finding with its original prefix (`[builder]` → Ready, `[qa]` → QA, both → `[builder]` first), `loop:rebuild-N`, and update the Reviewer report: those rows go to `❌ not fixed`. Skip the fresh pass; it would review code that is about to change.
   - An unfixed **Over-engineering** finding alone does not bounce; carry it into the new report's Findings.
   - All `fixed` / `no longer applies` → continue to step 4 for a fresh pass. Do not re-raise a prior finding marked `no longer applies`.
4. Review the code (logic, conventions). Review the tests (right thing tested? testable assertions? meaningful coverage?).
5. **Reviewer-side test rerun** (always — closes the Tester self-verification gap):
   - Pull `issue-<N>-<slug>` into the review worktree.
   - Re-run the test command Tester used (recorded in Tester's PR handoff comment as `Local tests:` line).
   - Tests green → continue to step 6.
   - Tests red → open new `[qa]`-prefixed PR thread quoting the failure output, move card Review → QA with `loop:rebuild-N`, exit. Tester wrote a broken suite; QA owns the fix.
6. **Adversarial mode** (per `truth_gate`): when triggered, spawn 2 sub-agents in parallel:
   - **Code-grounder** — verify cited file:line still exists and matches claims.
   - **Historian** — `git blame` the changed lines, check for ADRs / prior incidents.
   - **Budget cap (added 2026-05-22): each sub-agent ≤50 gh calls.** Prefer local `git blame` / `git log` over `gh api graphql`. If a sub-agent needs >50 calls to reach confidence, it returns `confidence: "insufficient_data"` and the Reviewer flags the card as 🛡 truth-check inconclusive instead of burning the shared quota. See `rate-limit-etiquette.md`.
   - **Brief:** use the fixed sub-agent brief in super-review → "Adversarial mode" verbatim. Never write your own. It states that Over-engineering is Should fix, never Blocker on its own, and never lowers confidence.
   - Aggregate into a confidence score (0-100). Compare against `config.truth_threshold` (default 70).
   - **Below threshold** — Reviewer MUST NOT approve. Open a `[reviewer]`-prefixed PR thread quoting the lowest-confidence sub-agent finding, write the full Block template comment (see §4 Block/Skip), move card Review → Blocked with reason tag 🛡 truth-check failed (confidence X/100). The card stays Blocked until human review; the bot's "Why I cannot decide" line names the specific sub-agent finding it could not confirm.
   - **Above threshold** — continue to step 7.
   - **No Reproducer needed** — Tester's tests were re-run in step 5.
7. Decide per finding. First re-apply the Over-engineering rule to every collected finding, whatever a sub-agent wrote: Should fix, never Blocker, never on its own a bounce or block. Then:
   - **No findings (Over-engineering aside) + threads clean + truth ≥ threshold + tests green** → run the **merge protocol** below. Do not move the card to Done any other way.
   - **Over-engineering only** (from `ponytail:ponytail-review`, see super-review step 3) → list it in the report, open no thread, and carry on to the merge decision; it never bounces a card alone. When the card bounces for another finding anyway, open a `[builder]` thread for each Over-engineering finding too, so the rebuild trims it.
   - **Code-side new finding** → open new `[builder]`-prefixed PR thread, comment, move card Review → Ready (label `loop:rebuild-N`).
   - **Test-side new finding** → open new `[qa]`-prefixed PR thread, comment, move card Review → QA (label `loop:rebuild-N`).
   - **CI-budget block (💳, added 2026-05-22)** — if remote CI jobs `failed_to_start` due to `Actions budget` AND `config.auto_merge_on_ci_budget_block` is true AND local-evidence is strong (truth ≥ threshold, Tester suite green on rerun in step 5, all `[builder]`/`[qa]` threads clean) → **squash-merge anyway** on local evidence; do NOT move to Blocked. Write the PR's `redcheck` block (`> [!WARNING]` · `🔴 Merged with a failing check: <check> · CI budget block`) and a `[reviewer] [report] ✅ merged · CI-budget bypass` comment on the PR and the issue citing: (a) the failed CI run ID, (b) the Tester pass-count, (c) the truth-gate score. Reason: CI failure-to-start ≠ test failure; with strong local evidence, parking the card wastes pipeline time. This bypass is ONLY for `💳` — never for `🛡` truth-fail, `🔐` missing creds, or `🧑` human-only decisions.
   - **Human-gate / Blocker finding (destructive schema, API contract, money, auth, live-DB migration) / rebuild cap hit (config.rebuild_cap)** → write the full Block template (see §4), move card Review → Blocked. A clean PR that only *touches* money, auth or schema is not a blocker — run the merge protocol; the gate's `merge_policy` routes it to a human (exit 7 → 🙋 Blocked).
8. Write the **Reviewer report** on every exit from step 3b on — bounce, block, human gate, merge (a Gate 1 thread bounce reviews nothing and writes none). It is ONE comment per PR, **edited in place** each round: find it by the marker (step 3b's lookup, plus `.url` — the number after `#issuecomment-` is its id) and `gh api -X PATCH repos/<owner>/<repo>/issues/comments/<id> -F body=@<file>`; post a new comment only when none exists. It is what step 3b reads next time, so the first line is the stable marker and every finding keeps its id (writing-standard.md § 4):

   ```
   <!-- super-review:report -->
   [reviewer] [report] ❌ bounced · round 2
   Did: checked R1–R2 against the code; fresh pass skipped (R2 open)
   ✅ Done: R1 fixed `src/api/stream.ts:54`
   ❌ Not done: R2 not fixed `e2e/streaming/ttfb.spec.ts:18`
   Next: builder

   | ID | Owner | Class | Where | Finding | Status |
   |---|---|---|---|---|---|
   | R1 | builder | Bug | `src/api/stream.ts:54` | <one line> | ✅ fixed |
   | R2 | qa | Verification miss | `e2e/streaming/ttfb.spec.ts:18` | <one line> | ❌ not fixed |
   | R3 | builder | Over-engineering | `src/api/retry.ts:1` | <what it builds → smaller thing> (should fix, not blocking) | open |
   ```
   Status words in the header: `merge-ready` · `bounced` · `blocked` · `human-gated` · `merged`. Keep every row across rounds; update its Status (`open` · `✅ fixed` · `❌ not fixed` · `no longer applies`). New findings take the next free id. Every finding names its class — Gap / Bug / Verification miss / Scope drift / Over-engineering (super-review → "Classify findings"); a checked hypothesis that held is not a finding, it goes on the `✅ Done` line.
9. Clean up worktree.

### Merge protocol (Reviewer only — added 2026-08-06, issue #9)

Builder opens every PR as a **draft**, and GitHub will not merge a draft: `gh pr merge --auto`
on a draft queues forever and never fires. A run that skipped this step produced two
substantial builds and landed **zero commits on `main` in six hours**. The Reviewer must
walk these steps in order, and the card **must not reach Done until the merge is confirmed
on the base branch**.

```
1. Mark ready      gh pr ready <PR>                     # idempotent; no-op if already ready
2. Merge through the gate (step 5), pinned to the reviewed head — never a bare
   `gh pr merge`. The gate applies `merge_policy` (who merges; `default: "human"`
   keeps a person on every merge) and `migrations` (which databases the robot may
   migrate) itself; the Reviewer does not second-guess either, it routes the exit code.
3. Confirm the merge LANDED, do not trust the exit code:
     gh pr view <PR> --json state,mergeCommit -q '.state + " " + (.mergeCommit.oid // "none")'
     Expect: MERGED <sha>.  Then verify the sha is reachable from the base branch:
     git fetch origin <base> && git merge-base --is-ancestor <sha> origin/<base>
4. Only after step 3 passes: close the issue, move card Review → Done, rewrite `status` (`> [!TIP]` ✅ Merged) and append the `history` row, post the `[reviewer] [report] ✅ merged` comment
   citing the merge commit sha.
5. Merge through the gate, never with a bare `gh pr merge`. Record the head you
   reviewed when review passes, and hand it to the gate:
     HEAD=$(gh pr view <N> --json headRefOid -q .headRefOid)   # at the moment review passes
     bash .claude/bin/super-board-merge-gate.sh --config <config> --pr <N> --expect-head "$HEAD" \
       --subject "<PR title>" --body-file <msg.md>
   <msg.md> = the PR's commit bullets, deduplicated, plus `Closes #<issue>` (writing-standard.md § 1).
   The gate takes the merge mutex, checks the PR head is still $HEAD, merges the CURRENT
   base into a scratch worktree at $HEAD, runs `config.verify_commands`, and only then
   squash-merges with `--match-head-commit $HEAD`. After a merge it runs `cleanup-wt --post-merge`
   when the `.claude/hooks/cleanup-wt.py` hook is installed (local only; a cleanup failure never changes the exit). Route by exit code:
     0 → merged; continue to step 4
     2 → the branch no longer builds against the base → **rebase pass** (see below)
     3 → GitHub refused after a green verify (branch protection, required check)
          → Blocked with the §4 template; this one really is a human's
     4 → another card holds the merge lock → leave the card in Review, next wave retries
     5 → the base does not merge in cleanly → **rebase pass** (see below)
     6 → the PR head is not the commit you reviewed (a push after review, or during
          verify). Your evidence is void: leave the card in Review with a `[reviewer]`
          comment naming both shas; the next wave reviews the new head
     7 → merge_policy: a human merges this one. Stdout carries one
          `human-gate: <money|auth|schema|size|default|policy> — <evidence>` line per
          hit. Card Review → **Blocked** with the 🙋 template: `Why blocked` names the
          category and evidence; `To unblock` = "[ ] review PR #<P> and merge it
          yourself" OR "[ ] comment `done` to approve — the next wave merges it";
          label `needs-you`, `blocked-by: -`. A human merge moves the card to Done the
          usual way; a `done` brings it back through `resume`, and the gate clears the
          policy hold only with a verified trusted approval of the current request.
     8 → 🙋 needs you. Stdout carries one `needs-you: <command>` line per human step
          (migration for an env outside `migrations.allowed_envs`, an allowed migrate
          command that failed, a `needs-you:` line in the PR body,
          `migrations.human_steps`). Card Review → **Blocked** with the 🙋 template
          (block-template.md → "🙋 Needs you"), the commands copied verbatim into
          `To unblock`, label `needs-you` on issue and PR, `blocked-by: -`. When the
          human comments `done` after the current pinned request, the wave planner
          verifies their permission and the head before resuming Review. For exits
          7 and 8, copy the gate's `approval-request:` line into the canonical issue
          block; link it from the PR without duplicating the request.
   → do NOT leave a card in Review on exit 2, 3, 5, 7 or 8. A card left in Review is
     re-picked next tick and re-reviewed forever, which is the re-dispatch waste
     tracked in issue #10. Exits 4 and 6 are the exceptions: 4 simply queued, and
     6 needs a fresh review of a commit nobody has reviewed yet.
```

**Ordering invariant.** `Done` means "merged" — or closed as not planned on purpose, with a 🤷
comment (there is no Skipped column). If step 3 cannot be satisfied, the card goes to Blocked,
never Done. Anything that reads the board — status, halt gate, the
landed-work progress signal — depends on Done meaning the code is on the base branch.

## Commenting cadence (issue + PR, every lane)

Every lane writes BOTH on every exit, in the comment format of writing-standard.md § 4:

```
[<role>] [<label>] <status-emoji> <status> · <context>
Did: <one line>
✅ Done: <what passed or landed, with sha / file:line / command>
❌ Not done: <what failed or was skipped, and why>   (omit when nothing)
Next: <builder | qa | reviewer | Eric | none>
```

- Role = who writes it: `builder` · `qa` · `reviewer` · `collect` · `orchestrator`. Label for a
  lane exit is `report`; `blocker` for a Block comment.
- ≤ 8 lines. Evidence before prose. An unchecked thing is never implied to pass.
- NEVER list changed files — the PR shows them. No restating the issue, no adjectives.
- Machine lines go last and do not count: `Local tests:` (Tester and Builder, the exact command
  the Reviewer reruns), `gh-quota-on-exit:`, `blocked-by:`.
- Run the prose through `humanizer` when installed (else the plain-words rules in
  writing-standard.md).
- The **issue comment** is the same header plus the PR link; the PR comment carries the detail.

Builder exit (PR):

```
[builder] [report] ✅ built · round 1
Did: added /api/stream and the client SSE consumer; no schema change, no new deps
✅ Done: AC1 stream opens `streaming.test.ts:12` · typecheck clean · `abc1234`
❌ Not done: AC2 TTFB under load — no load harness here
Next: qa
Local tests: npm test --run streaming
gh-quota-on-exit: graphql=4120/5000 rest=4870/5000
```

Builder exit (issue):

```
[builder] [report] ✅ built · PR #87 @ abc1234
Next: qa
```

Tester fail (issue and PR — screenshots mandatory for any UI-touching AC):

```
[qa] [report] ❌ failing · v1
Did: ran AC1–AC2 on desktop + mobile against `abc1234`
✅ Done: AC2 CLS 0.04
❌ Not done: AC1 TTFB 1240 ms (want < 800) — fixed looks like first byte under 800 ms
Next: builder
Local tests: npx playwright test e2e/streaming

| Viewport | Screenshot |
|---|---|
| Desktop 1920×1080 | ![desktop](https://github.com/<OWNER>/<REPO>/raw/<SHA>/docs/super-board/runs/issue-42-qa-v1/desktop.png) |
| Mobile 375×667 | ![mobile](https://github.com/<OWNER>/<REPO>/raw/<SHA>/docs/super-board/runs/issue-42-qa-v1/mobile.png) |
```

A pass uses the same table with screenshots of the **working** UI per AC.

Reviewer merge (issue):

```
[reviewer] [report] ✅ merged · `ef67890` on staging
Did: path Build → QA ❌ v1 → Build → QA ✅ v2 → Review ✅ · truth 95/100
Next: none
```

Block exits use the same header (`[<role>] [blocker] 🛑 blocked`) and the fields of
`block-template.md`. A card dropped on purpose (out of scope, won't do) is closed as not planned
and moved to Done with a `[<role>] [report] 🤷 dropped · <reason>` comment — there is no Skipped
column.

## Per-tick logic (~30s cadence)

```
1. Refresh project items + column counts via gh api
2. Re-validate preconditions (auth, pre-flight, columns)
3. Downstream-first dispatch by lane capacity:
   ├─ Review has cards + Reviewer idle → dispatch top of Review
   ├─ QA has cards + Tester idle       → dispatch top of QA
   └─ Ready has cards → top card labelled `qa` + Tester idle → Tester;
                         otherwise Builder idle → Builder

   Allocation rule: at most ONE worker per lane at a time.
   Max concurrency = 3 total workers (Builder + Tester + Reviewer),
   but never 3 Builders from a Ready backlog. GitHub issue assignees prevent two workers claiming the same card;
   the runner still must track lane idleness separately to prevent multiple
   same-lane workers.
4. Wait for any lane to finish OR 30s timeout
5. Re-read project state (lane may have moved a card)
6. Loop until done conditions met
```

## Worker contract (every lane on claim)

Claim uses a **GitHub Issue assignee mutex** — atomic compare-and-set via `gh issue edit --add-assignee`. Labels are descriptive only; the assignee is the lock.

```
1. ATTEMPT CLAIM (atomic):
   ├─ `gh issue edit <N> --add-assignee super-board-bot[bot]`
   │      (if a different assignee is already set → 422; treat as "already claimed")
   ├─ On 422 / conflict → another worker has it; skip this dispatch.
   └─ On success → continue. Apply descriptive label
       (loop:in-build / loop:in-qa / loop:in-review) for UI clarity only.
2. SANITY CHECK: issue body has `## Acceptance Criteria` with ≥1 bullet
   ├─ Missing → write the full Block template (see §4) with reason ❓
   │           release claim (`gh issue edit --remove-assignee`)
   │           move card to Blocked, continue with next card.
   └─ Present → proceed.
3. Do the lane's work (build / QA / review).
4. If this lane opened a PR or pushed changes, refresh [PR author notes](pr-author-notes.md).
   Comment evidence on issue + PR (writing-standard.md § 4) and rewrite your PR body blocks.
5. Move card to next column (or Blocked with the full §4 template; dropped on purpose → closed, Done, 🤷 comment).
6. RELEASE CLAIM (`gh issue edit --remove-assignee super-board-bot[bot]`) and remove descriptive label.
```

The `super-board-bot[bot]` identity is either (a) a GitHub App installed on the repo, or (b) the user's own account on solo projects — onboard step 2 picks which. The assignee mutex is reliable because GitHub serializes assignee writes per issue.

### Anti-zombie addendum (added 2026-05-22 after #381 worker storm)

Worker-side assignee claim alone is **not sufficient** — `claude -p` cold-start takes 10–30s, during which the dispatcher's next tick can fire another worker for the same card. The 2026-05-21 first-run produced **7 racing workers** (3 on #381, 4 on #382) before the dispatcher died from rate limit.

The dispatcher MUST also:

1. **Claim BEFORE spawning the worker** — `try_claim_assignee` runs in the dispatcher and only proceeds to `nohup claude -p` if it wins the assignee write. Closes the cold-start race.
2. **Write a local in-flight lock** — `.claude/super-board/inflight/<issue-N>` contains the worker PID. `top_card_in_column` skips any issue with a live lock even if the assignee write hasn't propagated yet.
3. **Cap one worker per lane** — track `BUILD_PID` / `QA_PID` / `REVIEW_PID`; do not dispatch to a lane whose prior PID is still alive.
4. **Reap stale locks each tick** — `reap_finished_locks` removes any lock whose PID no longer exists.
5. **Orphan-scan on startup** — refuse to start if any `claude -p .*super-board run` worker is already running from a prior crashed dispatcher.
6. **One board read per tick** — `super-board-card.sh items` once per tick, not per column lookup (~1 GraphQL point per 100 cards).

The three locks (assignee, in-flight file, lane PID) are defense in depth: any one of them alone has a race window; together they make a duplicate dispatch effectively impossible.

## Halt gates

| Gate | Action |
|---|---|
| `config.rebuild_cap` reached on same card + same root-cause hash | Move card to Blocked with full §4 template (reason 🛡), continue run |
| No card progresses for 3 ticks AND no lane is idle | Halt, dump state |
| Auth expires mid-run | Halt, ping user with refresh instruction |
| Pre-flight check fails on re-validation | Halt with the specific missing item |
| Merge conflict, or a stale branch the merge gate rejects | Move card to **`Ready`** with the `loop:rebase` label — NOT Blocked. See "The rebase pass" below |
| User-defined time/budget window reached | Graceful halt: finish in-flight workers, no new dispatches |
| Destructive action would be required (prod deploy, db drop, secret rotation) | Halt, never proceed; move card to Blocked with reason 🛡 |
| Block-rate alert: Blocked count > `config.block_rate_alert_pct` of initial Ready | Post the breakdown in the run report, continue run |

### The rebase pass

A merge conflict is not a human decision. It is a build task, and it belongs in the lane that is
allowed to push.

**Why this changed.** On 2026-08-20 a PR reached Review with 264 tests green and a 94/100 truth
gate, and could not merge: eleven hunks across five files, every one of them two tickets adding
members to the same interface on purpose. The Reviewer refused — correctly, because **the Reviewer
never pushes to the branch it is judging** — and moved the card to `Blocked`. Two further cards
were waiting on that one and parked behind it. The resolution, when a human finally did it, was
"keep both sides" in twelve of the thirteen hunks and one block of setup code moved into a
function. Three cards lost a wave to a mechanical edit.

**The rule.** On merge-gate exit 2 or 5:

```
[ ] label the issue `loop:rebase`
[ ] move the card Review → Ready  (NOT Blocked)
[ ] comment on the PR: which files conflicted, or which verify command failed, and its output
```

The Builder picks it up as an ordinary pass, routes `mattpocock-skills:resolving-merge-conflicts`,
and pushes. Its finish line is a **green verification**, not an empty `git diff --diff-filter=U`:
when a shared interface grows on both sides, the files git merged cleanly are where most of the
work is. In the run above, thirteen conflict hunks were followed by ten further files that merged
without a marker and still failed to typecheck.

`Blocked` is still correct when the rebase itself cannot be done: the two sides genuinely disagree
about behaviour, or resolving requires a product decision. That is a `❓` or `🧑` block with the
usual template — and, per §4, a `blocked-by:` line.

### The wave-start sweep

Before planning any wave, `super-board-wave-plan.sh` reports five lists the orchestrator must act on
**before** launching:

- **`sweep`** — `Blocked` cards whose blockers have all closed. Move each to `Ready` and comment
  naming what cleared it (`clearedBy` carries the numbers). They then join this very wave.
- **`stranded`** — `Building` cards with no claim. Nothing selects from Building,
  so a wave stopped mid-build leaves them there forever. Remove any leftover build worktree, keep
  the branch, move the card to `Ready`, and comment naming the branch. The legacy dispatcher does
  the same once at start (`reclaim_stranded_building`).
- **`resume`** — 🙋 `Blocked` cards whose newest pinned request has a later `done`
  from a human with verified write, maintain or admin permission, for the current
  PR head. Move each to **Review**; `needs-you:done` may be kept as a display label
  only. Do not create or copy approval evidence. The Reviewer re-runs the gate,
  which independently checks the request, current policy/steps and head, verifies
  the build, and runs allowed migrations. New code or a newer request needs fresh
  human approval; a label or old bare comment cannot bypass that hold.
- **`refreshApproval`** — a PR head changed while its card was still `Blocked`.
  Move it to **Review** and remove stale `needs-you:done` display labels. The Reviewer
  reviews the new code and lets the gate produce a new pinned request, then returns
  it to **Blocked** for a fresh human reply. This is not an approved resume.
- **`flag`** — cards whose `## Blocked by` section could not be parsed. Leave them where they are
  and comment asking for the line to be fixed, quoting the `why`. Never guess: a card treated as
  free on an unreadable line gets built against a base that does not have what it needs.

**Why the sweep exists.** `Blocked` used to be terminal. A card parked naming the issue it waited
for, that issue later merged, and nothing ever read the note back — the run's own done-condition
("only Blocked/Done cards remain") meant a closing blocker could not wake anything. Five
cards sat that way on a real board until a human opened it and noticed.

### Root-cause hash (used by the rebuild-cap gate)

To detect "same root cause" without depending on a model classifier, each lane writes a deterministic hash to its failure handoff comment:

```
root-cause-hash: <sha256 first 12 hex chars>
```

The hash inputs (joined with `|`):

1. Lane (`build` / `qa` / `review`).
2. Error class — first matched: `test_assertion`, `test_runtime`, `build_fail`, `lint_fail`, `merge_conflict`, `network`, `auth`, `quota`, `other`.
3. First 3 unique `file:line` frames from the captured stack trace / test output (sorted, normalized — strip absolute paths to repo-relative).

Two consecutive failures on the same card with **identical hash** AND **same lane** count as the same root cause. Hits `rebuild_cap` → Blocked.

Different hash on the same card resets the counter — the bot recognizes that progress has been made even if the card hasn't reached Review yet.

## Done conditions

The loop exits cleanly when:
- All active-pipeline columns are empty; OR
- Only Blocked/Done cards remain (Backlog is not part of a run); OR
- A halt gate fires.

## Run manifest

```
docs/super-board/runs/<YYYY-MM-DD>-<slug>.md
```

Records: config used, columns, target, per-card history (claim → completion → next column with evidence links), halt gates, final counts, per-lane wall-clock, resume command.

## Notification cadence

- **Start** — project, initial column counts, link to live status: `super-board status`.
- **Per card completion** — `✅ Tester → #41 passed all checks → Review`.
- **Per Block** — short headline + reason tag (`⛔ #19 blocked → 🔐 missing OPENAI_API_KEY`) + link to the full §4 template comment on the issue.
- **Every 10 dispatches** — brief column-count snapshot.
- **Block-rate alert** — when Blocked count exceeds `config.block_rate_alert_pct` of initial Ready: ping with breakdown ("11/30 Ready cards blocked: 🔐×6, 💳×3, ❓×2 — see project board"). One-shot per run (does not re-fire).
- **Final** — end column counts, total moved to Done, blockers (with reason-tag breakdown), total wall-clock.

## Worker rate-limit etiquette (read before any burst of gh calls)

Workers share the dispatcher's gh-auth token bucket. The dispatcher's `gh_rate_guard` does NOT protect worker traffic. Every worker MUST follow `rate-limit-etiquette.md` (in this directory):

- Move and read cards with `.claude/bin/super-board-card.sh --config <cfg> move <issue> <Status>` / `status <issue>` — 1 GraphQL point. Every "move card X → Y" in the lifecycles above means this call. Comments, labels and PR reads go over REST (`rate-limit-etiquette.md` → "Price list").

- Source `scripts/super-board-gh-guard.sh` at worker start.
- Call `sb_gh_guard_check 200` before any burst of gh calls (thread reads, sub-agent spawn, exit verification).
- Adversarial sub-agents are capped at 50 gh calls each — prefer `git blame` (local) over `gh api graphql`.
- Final PR handoff comment MUST include `gh-quota-on-exit: graphql=<n>/5000 rest=<n>/5000` (use `sb_gh_guard_summary`).
- On 403 / secondary-rate-limit: sleep 60s, re-check at threshold 500, then resume.

## Worker self-check (mandatory on exit, every lane)

Before releasing the claim assignee and exiting, every worker MUST verify:

- [ ] Issue comment AND PR comment both written (per "Commenting cadence" above).
- [ ] Card column move's mutation returned success. **Trust the exit code of `super-board-card.sh move`** — a re-read of the board was the per-worker quota tax (`rate-limit-etiquette.md` §3). If the mutation returned non-zero, preserve its unknown outcome, leave the assignee in place, and pause the run locally. Reconcile the remote card state before any repeat; never blindly retry a write or depend on a successful halt comment.
- [ ] Claim assignee released (`gh issue edit --remove-assignee <bot_identity>`) and the descriptive `loop:in-*` label removed.
- [ ] On failure handoff: `root-cause-hash:` line is present in the PR handoff comment (per "Root-cause hash" above).
- [ ] On Block/Skip exit: the full template from `block-template.md` is populated on BOTH the issue and the PR (if a PR exists); the reason emoji is one of the nine in the vocabulary table (🔐 💳 🔑 ❓ 🛡 🧑 🤷 📦 🎨).
- [ ] `gh-quota-on-exit:` line appended to PR handoff comment.

A worker that cannot satisfy this checklist must NOT release its claim. It either fixes the gap and re-checks, or — if the gap itself is structural (e.g., GitHub API refusing to move the card) — it leaves the assignee in place and writes a halt comment so the runner's "no progress for 3 ticks" gate can fire deterministically.

### Known issue — multi-attempt card moves (added 2026-05-22)

During the 2026-05-21 production run, several workers exited cleanly (process terminated, in-flight lock reaped) but **had not moved their card to the next column**. The dispatcher correctly re-dispatched (lane idle + card still in source column = re-fire) — but each retry burned a full lane cycle (~10 min) before the next worker tried again. The #382 Reviewer took **5 attempts × ~10 min = ~50 min** to move a card that the first attempt should have moved.

Suspected causes:
- Worker lost the response to a column move and exited "cleanly" without confirming its outcome. Preserve the unknown outcome and pause; do not claim success or blindly repeat the mutation.
- Worker's super-build/super-qa/super-review skill silently caught the move error and proceeded to assignee-release without surfacing the failure.

**Mitigation for now:** the dispatcher's `reap_finished_locks` + assignee sweep + re-dispatch keep the pipeline rolling, so this is a wall-clock issue, not a correctness issue. A worker that doesn't move the card will eventually have another worker do it.

**Required behavior:** check the shared halt record before a column move, attempt the mutation once, and preserve `move-mutation-result: ok|unknown|skipped` in the handoff. An uncertain outcome pauses the run for read-only reconciliation; it must never trigger blind replay.

### Known issue — lane-zombie workers (added 2026-05-24, auto-remediated)

**Symptom seen on fitbox-v4 first run:** a Tester worker successfully moved #81 QA → Review and the Reviewer subsequently merged it to Done — but the original Tester's `claude -p` process kept running for 30+ minutes afterward. The dispatcher's `lane_idle()` check uses `kill -0` on the lane PID and saw the zombie as "still busy," so the QA lane never re-dispatched. By the time it was noticed, the QA column had grown 1 → 2 → 3 cards with no Tester picking them up.

Different from the multi-attempt-move issue above: there the worker exited without moving the card; here the worker moved the card but didn't exit.

**Auto-remediation (now implemented in `super-board-run.sh` as anti-zombie control #7):**

Every tick — both cheap and expensive — `sweep_lane_zombies` runs `check_lane_zombie` for each lane. For each lane whose PID is alive AND whose claimed issue's current column is NOT in the lane's expected source set:

| Lane    | Expected source columns | Anything else means → |
|---------|-------------------------|-----------------------|
| build   | Ready, Building         | zombie                |
| qa      | QA                      | zombie                |
| review  | Review                  | zombie                |

On zombie detection: `SIGTERM` + 1s + `SIGKILL` the PID, remove the inflight lock, idempotently sweep the assignee, clear the lane PID/issue vars, log `💀 zombie <lane> worker on #<N> (pid=<P>) — card moved to '<col>'; killing`. Uses the cached project items only — zero extra API calls per tick.

Trade-off: if someone (human or external tool) manually moves a card out of its source column while a worker is legitimately mid-work, the watchdog will kill that worker. Acceptable — manual board edits during an active run are an anti-pattern, and the worker would fail on its own column-move anyway.
