---
name: super-qa
description: >-
  Super QA canonical workflow for functional bug-bash, evidence capture, and fix-ready issue filing.
  Builds and runs Playwright path specs from `docs/super-qa/queue.md`, records screenshots/logs/HARs,
  files product-readable issues with clear type/priority/area labels, and continues until traversal is
  complete or only human-gated blockers remain. Use when the user says "run super-qa", "QA review",
  "bug bash", "verify and fix", or invokes `/super-qa`.
---

# super-qa — BFS Route-Crawler that Builds the Spec Suite

## Auth bootstrap — auto-discover, never ask

Before iter 1, resolve a test login. **Never ask the user; discover or create.** Order:

1. **Cached creds** at `.claude/settings.local.json` `.e2e.user` / `.e2e.pass` — use them as-is.
2. **Env-file fallback** — read in order: `.env.production.local`, `.env.local`, `.env`. Pull `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY`. If both present, auto-create `e2e-test@<owner-domain>` (owner from `git config user.email` domain, fallback `erictech.ca`) via:
   ```bash
   curl -sS -X POST "$SUPABASE_URL/auth/v1/admin/users" \
     -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
     -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
     -H "Content-Type: application/json" \
     -d "{\"email\":\"$E2E_USER\",\"password\":\"$E2E_PASS\",\"email_confirm\":true,\"user_metadata\":{\"role\":\"e2e-test\",\"created_by\":\"super-qa-bootstrap\"}}"
   ```
   Generate a 24-char random password (`openssl rand -base64 24 | tr -d '/+=' | cut -c1-24`). Save to `.claude/settings.local.json` `.e2e` so the next run skips bootstrap. Verify by logging in (`POST /auth/v1/token?grant_type=password` returns access_token).
3. **Unauth-only fallback** — if neither cached creds nor env-file admin key exist, log "no admin key — restricting to public routes" and proceed with `/login`, `/signup`, `/forgot-password` only. Do NOT halt.

The bootstrap is **non-interactive**. If the curl returns an existing-user error (`User already registered`), reset the password via the same admin endpoint and continue. Save creds either way.

## QA loop state board — GitHub Project as the state store

State for the QA↔Build loop lives in a GitHub Project named **`Super Ultimate QA`** (auto-discovered by title at the user/org level). It has six Status columns matching the PDF model:

| Column   | Meaning                                              |
|----------|------------------------------------------------------|
| Queue    | Work the next iteration will pick up                 |
| Testing  | Feature currently being explored or verified         |
| Done     | Spec passing, no action needed                       |
| Bug      | Failing spec; Super Build picks these up next        |
| Flaky    | Only passes on retry; quarantine + investigate       |
| Skip     | Out of scope; documented and parked                  |

This board is the durable, machine-readable state for the loop. `docs/super-qa/queue.md` remains the BFS route seed and audit log, but **all actionable findings land on the project board** so `super-orchestrator` can gate on `Bug` column non-empty without parsing markdown.

### Project resolution

Resolution order (used by `scripts/super-qa-file-bug.sh` and the orchestrator):

1. If `SUPER_QA_PROJECT_TITLE` is set, query `gh project list --owner $SUPER_QA_PROJECT_OWNER --format json` and pick the project whose title matches (case-insensitive).
2. Otherwise default to title `Super Ultimate QA`.
3. Owner defaults to `$(gh repo view --json owner -q .owner.login)` or `SUPER_QA_PROJECT_OWNER` if set.

If no matching project exists, the loop halts with a one-line error and instructs the operator to create one. Do not silently fall back to the repo's primary project — column semantics differ.

### Filing semantics

When the worker finds a red spec, it calls `scripts/super-qa-file-bug.sh`. The script:

- Creates the issue with `source:qa` label and full evidence body.
- Adds the issue to the resolved **Super Ultimate QA** project.
- Sets the Status field to `Bug` (override with `SUPER_QA_TARGET_OPTION_NAME`).

A `Flaky` retry-only finding goes to `Flaky`; out-of-scope routes go to `Skip`. The same issue may also live on a repo-level project for normal triage — Status on the QA project is the loop state; status elsewhere is independent.

## Algorithm overview

You are the orchestrator. Your job: drive a BFS crawl of the target EricTechOS app
that **builds `e2e/paths/` into a comprehensive Playwright suite** while
fixing any bugs it stumbles on. Each iteration is a fresh headless
`claude -p` worker that does ONE iter and exits. There is no worktree —
the worker commits directly to the active branch (default `main`).

## Autonomous mode — NO AskUserQuestion mid-loop

`/super-qa` is invoked by an operator who walks away (often overnight,
phone-only via Telegram). The loop must run end-to-end without the
orchestrator pausing on `AskUserQuestion`.

**Decide-and-proceed, don't ask, on these classes of issue:**

- Dispatcher / harness script bugs (parser errors, broken xargs, missing
  `chmod +x`, stale lock files). Fix locally, commit with a `fix(super-qa):`
  prefix, then continue.
- Missing env auto-loads, leftover MCP zombies, log-dir creation.
- Lint / formatting nits introduced by the worker that block its own commit.
- Choosing between equivalent dispatch modes (sequential vs sequential —
  parallel is unsafe, never picked).

**Still halt on these (real forks):**

- Critical-path HUMAN GATE (dispatcher exit 4) — production money flow
  red >2 iters. Mandatory halt per skill contract.
- Dispatcher exits 2 / 3 with a worker error that isn't a script bug
  (e.g. Anthropic API down, prod Railway 503, auth credential rejected).
- Working tree dirty with changes the orchestrator didn't make (could be
  user's in-flight work).
- Anything that would delete or rewrite history (`git reset --hard`,
  force-push, branch deletion).

**Status updates instead of questions:** when you make an autonomous fix,
report it in the next status message — what was broken, what you committed
(with SHA), and a one-line revert path. Telegram is the channel; if it's
down, log to terminal output and continue.

After this loop has run for a while, `e2e/paths/` is the deliverable. CI runs
`npm run test:e2e` on every PR. **No AI involvement in steady-state
regression.** AI is only needed to extend the suite when new pages ship.

```
                AI loop (build phase)            CI (steady state)
               ─────────────────────             ──────────────────
/super-qa      →  e2e/paths/    →    npm run test:e2e on PR
(drains queue.md,        grows toward         catches regressions
 fixes bugs)             comprehensive        without any AI tokens
```

**This skill is INDEPENDENT of `/super-build`.** They share no state.
`super-build` executes new sessions from the GitHub Project board (forward
progress); `super-qa` hardens what already ships by exhaustively
walking the route tree.

## The queue is the curation surface

`docs/super-qa/queue.md` is a markdown checklist the loop reads from
and writes to. Four states per line:

- `[ ]` queued — will be popped next
- `[x]` green spec exists (links to the spec file + iter discovered)
- `[!]` skipped permanently (with reason)
- `[b]` bug found here, children NOT pushed; will be re-tried after fix
- `[?]` flaky — passed on retry, not a bug yet (see flaky policy below)

The queue is **append-only at the back** during normal exploration. The user
can hand-edit it to reorder (turn BFS into DFS for one branch, push something
to the front, etc.). The skill respects whatever the user wrote.

The seed is `client/src/routes.ts` — every static route becomes a `[ ]`
entry under "Level 0".

## Findings land in clear GitHub Issues, NOT in markdown

Every `[b]` cell triggers the worker to call `scripts/super-qa-file-bug.sh`.
The resulting Project card must be readable from the board without opening it.
Do **not** use legacy `[VFL]`, `verify-fix`, or `severity:P*` wording in new issue titles.

**Title format:**

```text
<emoji> <Type> <route?> — <short action/result>
```

Examples:

```text
🐛 Bug /imports — CSV upload fails after submit
🎨 UX /settings/users — Add user button is a no-op
🧪 Tests /orders — missing coverage for failed payment state
📝 Docs /delivery — SPEC section missing for dispatch flow
```

**Priority labels use plain words:**

- `priority:high` — urgent, release-blocking, data-loss, security/auth, money, or critical feature broken.
- `priority:medium` — important feature degraded, important edge case, a11y/i18n issue, or user confusion that should be fixed soon.
- `priority:low` — polish, cosmetic, copy, documentation, testability, or cleanup.

**Required labels:**

- Type: `bug`, `feature`, `ux`, `tests`, `docs`, or `tech-debt`.
- Source: `source:qa`.
- Priority: `priority:high`, `priority:medium`, or `priority:low`.
- Area: `area:<product-area>` when known (`area:settings`, `area:imports`, `area:admin-shell`, etc.).
- QA category when relevant: `qa:functional`, `qa:visual`, `qa:network`, `qa:console`, `qa:i18n`, `qa:a11y`, `qa:data`, `qa:testability`.
- Suggested skill owner when helpful: `skill:super-build`, `skill:super-qa`, `skill:super-ux`, or `skill:super-review`.

The script adds the issue to the resolved `Super Ultimate QA` project and moves it into the `Bug` column (override with `SUPER_QA_TARGET_OPTION_NAME`) so `super-build` in QA-loop mode (or a human) can pick it up immediately. The repo's standalone feature project is not touched by this flow.

The `iteration-N.md` Section 3 is the per-iter audit (with `gh_issue: <N>` back-references); the GH issue is the durable tracker. The fix-commit message includes `(closes #<N>)` so the issue auto-closes on merge.

**Triage all loop-filed findings:**
```bash
gh issue list -l source:qa --state open
```

This is a carved exception to the project rule "ask before `gh issue create`": the loop is autonomous and unattended, so it is authorized to auto-file — but ONLY with the clear `source:qa` label and the evidence template below.

### Required issue body template

Every auto-filed finding must give a future headless Claude/Super Build session enough context to fix it without re-discovering the bug from scratch:

```markdown
## Summary
<one sentence: what is wrong and where>

## Repro steps
1. <exact login/route/action>
2. <next action>
3. <observed failure>

## Expected behavior
<what should happen, citing SPEC.md, DESIGN.md, or product intent when possible>

## Actual behavior
<what happened instead>

## Evidence
- Screenshot: <embedded image or repo/raw path>
- Console: <0 errors or paste relevant lines / path to console.log>
- Network: <failed requests or path to network.json/HAR>
- Page errors: <0 errors or path to pageerrors.log>
- Spec: `<e2e/paths/...spec.ts>`

## Suggested fix path
- Suggested owner: `super-build` | `super-ux` | `super-qa` | `super-review`
- Suggested skills: `systematic-debugging`, `test-driven-development`, `verification-before-completion`
- Notes for implementer: <first suspected file/function, if known>

## Acceptance criteria
- [ ] <user-visible behavior fixed>
- [ ] <Playwright/regression coverage added or updated>
- [ ] <Super QA rerun passes this route>
```

If a screenshot/network/console artifact does not exist, explicitly write `not captured` and explain why. Do not leave evidence ambiguous.

### Filing guardrails

`super-qa-file-bug.sh` validates issue bodies before filing. It must reject weak tickets that are missing required sections or still contain placeholders like `TBD`, `<...>`, or `TODO:`. Do not bypass this with `SUPER_QA_ALLOW_WEAK_BODY=1` during normal autonomous runs.

Every filed issue must include:

- `## Board summary` near the top for quick project-card context.
- A hidden `super-qa-meta` block with route, spec, iteration, area, category, priority, type, and `fingerprint`.
- A deterministic fingerprint. Use a meaningful key when known, such as `settings-users|add-user|no-op`; otherwise the script derives one from kind/route/category/title.

Dedupe policy: before creating a new issue, the script searches open `source:qa` issues for the fingerprint. If a match exists, it comments with the new evidence and returns the existing issue number instead of creating a duplicate Ready card.

## What counts as "green" — non-blank guards + forensics

A 200 response with a blank body is a bug, not a green test. Every spec
under `e2e/paths/` enforces:

- **No console errors** (`level === 'error'` only)
- **No uncaught page errors** (`page.on('pageerror', ...)`)
- **No 5xx network responses** during the run
- **No 401/403** on auth-required pages
- **Type-specific non-blank guard** (e.g., list-page: ≥1 row OR
  empty-state element; dashboard: ≥1 widget with non-`—` data) — see
  `docs/super-qa/page-types.md` "Non-blank guard" column

If any of those fire → cell is `[b]` → bug filed.

Per-spec forensics captured by `e2e/lib/report-fixture.ts`:

| Artifact | Path |
|----------|------|
| Screenshot per `report.step()` | `docs/super-qa/report/<slug>/tc-N/<locale>/*.jpg` |
| Console errors | `docs/super-qa/report/<slug>/tc-N/<locale>/console.log` |
| Page errors | `docs/super-qa/report/<slug>/tc-N/<locale>/pageerrors.log` |
| Network HAR | `docs/super-qa/report/<slug>/tc-N/<locale>/network.har` |
| Network summary | `docs/super-qa/report/<slug>/tc-N/<locale>/network.json` |
| Sentry probe | `docs/super-qa/report/<slug>/tc-N/sentry-events.json` |

The fixture (`e2e/lib/report-fixture.ts`) **already captures** console
errors, page errors, failed requests, network summary, and Sentry events,
plus HAR via `recordHar`. Disk writes are gated behind
`SUPER_QA_FORENSICS=1`, which `scripts/super-qa-dispatch.sh` exports for
every iter. Fixture exposes everything via `report.forensics.*` (e.g.
`report.forensics.consoleErrors`). Iter 2's only fixture-related task is
to retrofit the assertions onto the 5 existing specs (login, dashboard,
orders, orders-new, order-detail) — see preamble Phase 1.

## Algorithm

### 1. Determine iteration count
- If user provides arg (e.g. `/super-qa 5`), use that count.
- If `--resume`, start at `max(existing iteration-*.md) + 1`.
- Default: **10 iterations, sequential**. (Concurrency is unsafe — workers
  share `queue.md`. To run parallel work, branch and run a second
  orchestrator.)

Notify Telegram once: `🐛 Super QA starting — N iterations`.

### 2. For each iteration N (sequential)

**2a. Pre-flight**
- `next_n = max(existing iteration-*.md numbers in docs/super-qa/iter/) + 1`. If none exist, start at 1.
- Confirm working tree is clean (`git status` has no staged/unstaged tracked
  changes — untracked files are OK). If dirty → halt and notify.
- Verify `docs/super-qa/queue.md` exists. If not, refuse to dispatch
  and report — the queue is hand-seeded once via this skill's setup
  (or already by the commit that introduced the skill).

**2b. Dispatch iteration worker**
```
bash scripts/super-qa-dispatch.sh <next_n>
```
…via Bash with `run_in_background: true` (so the orchestrator can poll). The
dispatcher:
- Composes prompt = `references/iteration-preamble.md` + per-iteration footer
  (iter num, base SHA, mandatory final-commit format).
- Runs `claude -p --dangerously-skip-permissions --max-turns 250` in repo
  root (no worktree creation).
- Verifies the worker produced a `super-qa: iter N` commit on the
  current branch.
- Exit codes: `0` (iter complete) / `2` (worker non-zero) / `3` (no
  done-commit) / `4` (HUMAN GATE) / `5` (WIP-CHECKPOINT — wall-clock hit
  mid-fix, picks up next iter).

Notify Telegram: `🔍 Iter N dispatched`.

**2c. Wait, then advance**

Poll BashOutput. On dispatcher exit 0:
- Read the close-out commit subject to extract `(X bugs, Y items)`.
- Notify Telegram: `✅ Iter N done — X bugs, Y items processed`.
- Loop to next iteration.

On dispatcher exit 2 / 3 / 4 / 5:
- Notify Telegram with `tail -50` of `.planning/super-build-logs/super-qa-iter-N.log`.
- Halt the loop (unless `--continue-on-error` was passed).
- Exit 4 (HUMAN GATE) is mandatory halt regardless — see "critical paths"
  below.
- Exit 5 (WIP) is **not** halt; the next iter's regression phase finds the
  red spec and finishes the fix. Continue.

### 3. Termination check (after every iter)

Stop when **any** of:

- Queue has no `[ ]` items left — natural completion.
- User-supplied iteration count `N` is reached (the `N` in `/super-qa N`).
- Dispatcher halt gate fires (HUMAN GATE, dirty tree, dispatcher exit 2/3/4).
- User interrupts.

**Notification trigger (NOT a stop):** after 3 consecutive iters with zero
bugs found, send a Telegram summary like *"diminishing returns: 3 iters, 0
bugs, N items still in queue — continuing"*. The loop continues until the
queue actually drains (or `N` is reached). The user can interrupt manually
if they accept the diminishing returns.

Rationale: zero bugs in recent iters does not prove the unexplored remainder
of the queue is clean. The only way to know is to keep going. The previous
"3 zero-bug iters" auto-halt was budget pragmatism dressed up as completeness.

Coverage % is reported every iter as a progress indicator, never a gate.

### 4. Final report

After termination (or on halt):
- Aggregate: total iters, items moved from `[ ]` → `[x]` / `[b]` / `[!]`,
  total bugs found, total fixed, queue size now.
- Send Telegram summary linking to all `docs/super-qa/iter/iteration-*.md`
  and the current `docs/super-qa/report/QA-REPORT.md`.

## One iteration, in plain English

The worker (per iter N) runs three phases:

**Phase 1 — Regression.** `npx playwright test e2e/paths/` against
everything. Any red spec? Apply the retry policy (re-run once in isolation).
Real reds get filed as bugs in `iteration-N.md`, fixed via TDD, re-run until
green. This is the "verify what we already have" step.

**Phase 2 — Explore.** Until the budget is hit (default: 5 cells popped
OR 30 min wall-clock):
1. Pop the top `[ ]` item from `queue.md`.
2. Classify via the URL-pattern heuristic in `docs/super-qa/page-types.md`.
3. Write a spec at `e2e/paths/<slug>.spec.ts` using the test recipe for that type.
4. Run it.
   - **Green** → mark `[x]`. Walk the rendered page; push newly-discovered
     children (links / buttons / dialogs / tabs — see preamble for the
     verbatim "what counts as a child" rule) to the back of the queue. Cap
     children pushed per page at **10**.
   - **Red** → file the bug to `iteration-N.md`. **Mark `[b]`. Do NOT push
     children.** Try to fix via TDD if budget allows; otherwise leave for
     next iter. After fix, re-mark `[ ]` so a future iter expands the
     subtree.

**Phase 3 — Report.** Write `docs/super-qa/iter/iteration-N.md` (bugs
found, items processed, queue size before/after, coverage snapshot). Run
`npm run qa:report:render`. Commit:
`super-qa: iter N (X bugs, Y items, Z PRs opened)`.

## The bug-handling rule (non-blocking)

> When a spec goes red, the worker logs the bug, marks the item `[b]`, **stops
> expanding into that subtree**, and continues with the rest of the iter's
> batch. Other siblings in the queue still get tested.

A bug on `/customers/:id` shouldn't block exploration of `/orders` or
`/dashboard`. Maximum coverage per iter; one bug never halts the loop.

Fix can happen:
- **Same iter** — if budget allows, the worker runs TDD on the bug after
  the explore phase.
- **Next iter** — if budget exhausted, the bug sits in `iteration-N.md` and
  Phase 1 of iter N+1 finds the red spec and finishes the fix.
- **Manually by human** — fix it whenever; the loop picks it up on the next
  regression pass.

After fix, the `[b]` item gets re-marked `[ ]` and a future iter processes
it (and pushes its children).

## Page-type taxonomy

Classification gives the worker a test recipe per kind of place. See
`docs/super-qa/page-types.md` for the canonical list:

```
list-page       form-page       settings-page
detail-page     dashboard-page  modal/drawer
public-page     import-flow     wizard
                                settings-tab
```

Classification order: URL-pattern heuristic first (cheap default) → AI
override if the heuristic looks wrong → hand-curated override in
`page-types.md` if the user wants to lock something in.

## Critical paths (HUMAN GATE)

`docs/super-qa/critical-paths.md` is a hand-curated list of
money-flow specs that MUST always be green (login, create order, take
payment, run cutoff snapshot, send driver email). The user maintains it;
the skill never auto-edits it.

If any critical-path spec has been red for **>2 consecutive iters**, the
dispatcher exits **4 (HUMAN GATE)**. The loop halts. A human investigates.
This protects production-critical flows from being silently broken by
in-flight queue items.

## Multi-step user journeys — `docs/super-qa/flows.md`

`critical-paths.md` is the *money-flow guard* (login, checkout, payment) —
small, hand-curated, mandatory human gate if red >2 iters. It is **not** a
coverage layer.

`docs/super-qa/flows.md` is a separate, broader hand-curated list of
*multi-step user journeys* the BFS crawler doesn't reliably exercise on its
own. Examples:

- create user → set role → user logs in → sees their assigned region
- import CSV → review preview → confirm import → verify rows in `/orders`
- create order → assign driver → driver email mock fires → order moves to dispatched

Each entry in `flows.md` is one line per flow with a slug. The worker
generates or updates `e2e/flows/<slug>.spec.ts` for each entry. Specs in
`e2e/flows/` run alongside `e2e/paths/` in Phase 1 regression — same fixture,
same forensics, same `[b]` rules apply. They are **not** pushed via BFS
expansion; they exist as hand-curated chains.

Flows take precedence over individual route specs when both exist for the
same endpoint — a green `e2e/paths/orders.spec.ts` doesn't override a red
`e2e/flows/create-order-end-to-end.spec.ts`.

The user maintains `flows.md`; the skill never auto-edits it. To add a new
flow, the user hand-edits the file; the next iter's Phase 1 picks up the
new slug and generates the spec from a flow recipe.

### `flows.md` template (the worker creates this on first encounter if missing)

```markdown
# super-qa multi-step user journeys

One line per flow. Format: `- slug — short description (route1 → route2 → ...)`

The worker generates / updates `e2e/flows/<slug>.spec.ts` per entry.
These run in Phase 1 regression alongside `e2e/paths/`.

## Flows

- onboard-user — create user, set role, user logs in, sees their region
  (/admin/users/new → /login → /dashboard)
- import-csv-end-to-end — import CSV, review preview, confirm, verify rows
  (/imports → /imports/preview → /orders)
```

## Skill dependencies

The worker (per `references/iteration-preamble.md`) must load and follow:

- `superpowers:using-superpowers`
- `superpowers:test-driven-development`
- `superpowers:systematic-debugging`
- `superpowers:verification-before-completion`
- `playwright-best-practices` — when writing or refactoring a spec. Reference
  its `locators.md` (data-testid first, `getByRole` fallback),
  `fixtures-hooks.md` (custom fixtures for auth, pre-test seeding, teardown),
  `test-data.md` (test data factories), and `page-object-model.md` (POM for
  reusable interactions). Keep specs reusable as the suite grows.

## Coexistence with `/super-build`

`super-qa-file-bug.sh` files bugs into the **Super Ultimate QA** project's `Bug` column. This is a separate board from `/super-build`'s standalone feature queue (`BUILD_LOOP_PROJECT`), so the two skills can run concurrently without column races:

- **Standalone `/super-build`** keeps reading `Ready` from its configured feature project (e.g. `Fitbox Admin #2`). Untouched by `/super-qa`.
- **Orchestrator-driven `/super-build` in QA-loop mode** drains the `Bug` column on `Super Ultimate QA` and moves cards to `Done`. `super-orchestrator` gates on this column being empty before kicking off the next QA wave.

If you intentionally want a single board for both lanes, set `BUILD_LOOP_PROJECT=$SUPER_QA_PROJECT_NUMBER` and `BUILD_LOOP_QA_MODE=1`. Don't do this by accident — the column semantics differ.

## Test target & safety rails

The default target is the app target configured by `BASE_URL`. Treat production URLs as production and prefer preview/staging for mutating flows.

Safety rails (enforced by the iteration preamble):
- Test user: configure via app env, for example `QA_BOT_EMAIL` / `QA_BOT_PASSWORD`.
- All written test data is prefixed `[TEST] ` so it's greppable.
- Sentry tag `source=super-qa` on errors.
- DB resets DISABLED (`RESET_DB=false`) — would wipe prod.
- Email sending mocked via `RESEND_API_KEY=mock_<anything>`. **Required:** run against a staging deploy (`NODE_ENV=staging`, `EMAIL_DRY_RUN=1`) — not prod. See `docs/super-orchestrator/STAGING-ENV.md` for the 7-step playbook. If no staging URL is configured, halt with `STATUS: halt (no-staging-env)`.
- Override the target via `BASE_URL=…` env var on the dispatcher.

## Files involved

```
.claude/skills/super-qa/
├─ SKILL.md                            ← orchestrator instructions (this file)
└─ references/
   └─ iteration-preamble.md            ← worker contract (verbatim prompt)

scripts/
└─ super-qa-dispatch.sh         ← thin dispatcher

docs/super-qa/
├─ README.md                           ← operator's guide
├─ HANDOFF.md                          ← context handoff
├─ queue.md                            ← THE queue (loop reads/writes)
├─ page-types.md                       ← taxonomy + per-page overrides
├─ critical-paths.md                   ← hand-curated money-flow guard
└─ iter/
   ├─ iteration-1.md                   ← per-iter bug log + report
   └─ ...

e2e/paths/                             ← THE deliverable (one spec per place)

docs/super-qa/report/
└─ QA-REPORT.md                        ← regenerated every iter (existing)
```

## Recovery / re-entry

- Default: starts a new batch numbered after the last `iteration-*.md`
  (e.g. if iters 1-5 exist, the next batch starts at 6).
- `--resume`: only run iters whose number is greater than `max(existing)`.
- A leftover `wip:` commit on the current branch (from a dispatcher exit 5)
  is OK — the next iter's regression phase finds the red spec and finishes
  the fix.

## Stop conditions

- Queue empty (no `[ ]` items left) — natural completion.
- Iteration count reached (the user-supplied `N`).
- Dispatcher exit 2 / 3 / 4 — halt and notify.
- User interrupts.

**Note:** "3 consecutive zero-bug iters" is **no longer** a stop condition.
It triggers a Telegram notification ("diminishing returns") but the loop
continues exploring the rest of the queue. See "Termination check" above
for rationale.

## Invocation patterns

- `/super-qa` → 10 iters, sequential, default budget
- `/super-qa 5` → 5 iters
- `/super-qa --resume` → continue from `max(existing) + 1`
- `/super-qa --continue-on-error` → don't halt on a single iter failure

## Companion skill

`/super-build` executes pending issues from the GitHub Project board.
Independent of this skill — they share no state. Run `/super-build` to make
forward progress; run `/super-qa` to grow the spec suite + harden
shipped code.

## super-board integration

When invoked by super-board (env `SUPER_BOARD_RUN=1` or invocation contains "super-board run"):

### State protocol (same as super-build)
- Read from issue + PR comments + PR review threads.
- Respect handed-down worktree + branch.

### Variants
- **Repo-backed:** worktree at `.worktrees/issue-<N>-qa/` checked out at Builder's branch tip.
- **URL-target mode (QA-only variant on URL target):** NO worktree, NO branch. Hit `config.target.url` directly with `curl` / Playwright / `browse`.

### Lifecycle (Tester, first pass)
See `.claude/skills/super-board/references/run.md` → Tester (first pass — repo-backed). Summary:
1. Pull latest of base; checkout `issue-<N>-<slug>` into worktree (skip if URL-only).
2. Read issue + PR + Builder's handoff.
3. Build issue-scoped test plan: ONE observable test per AC.
4. Run tests. Capture evidence to `docs/super-board/runs/issue-<N>-qa-v<N>/`. **For any UI-affecting issue, capture at least one screenshot per AC** (Playwright `page.screenshot` or `browse --screenshot`). Save with descriptive names: `ac1-<short-desc>.png`, not `screenshot1.png`.
5. **Commit the evidence directory** to the issue branch alongside test files (`git add docs/super-board/runs/issue-<N>-qa-v<N>/ && git commit && git push`). This is non-optional — without it, the inline image markdown in the issue comment won't render on GitHub.
6. **Pass** → 🔍 PR comment with results + evidence path → 🔍 **issue comment with screenshot evidence** (see "Issue-comment evidence format" below) → move QA → Review. Clean up worktree.
7. **Fail** → 🔍 PR comment with per-AC expected/actual + repro file:line + evidence path + "what fixed should look like" → 🔍 issue comment with the failure screenshots → increment rebuild counter → move QA → Ready (label `loop:rebuild-N`). Clean up worktree.

### Pass-handoff PR comment MUST include the test command
Every Pass-handoff PR comment includes a `Local tests:` line with the EXACT command Reviewer will re-run as the self-verification gate:
```
Local tests:  npm test --run streaming
```
This is non-optional. Reviewer re-runs this command; red → bounce back to QA.

### Issue-comment evidence format (REQUIRED — both pass and fail)

The Tester's issue comment is the user's primary visibility into "is this actually fixed." A bare directory path is not sufficient — the user wants to *see* the proof on the issue page.

**The canonical template lives in `.claude/skills/super-board/references/run.md` → "Screenshot embed format" (right after Tester first pass).** Do not duplicate it here; both lanes (super-board Tester + standalone super-qa) follow that exact format. Summary of rules workers must obey:

- Capture screenshots at the standard viewports for UI ACs: **desktop 1920×1080, tablet 1024×768, mobile 375×667**.
- Commit the screenshots to the issue branch *before* writing the comment — inline image URLs won't render unless the file is on the branch.
- Use the `https://github.com/<OWNER>/<REPO>/raw/<BRANCH>/...` URL form so images render even when the branch isn't default. Resolve `<OWNER>/<REPO>` from `git remote get-url origin`.
- Embed the same screenshots in BOTH the PR timeline comment AND the issue comment — the issue page is the user's primary view.
- Include a "Local path" bullet list alongside the inline images so the user can also open them in their IDE.
- For non-visual ACs (API tests, migration SQL), skip the screenshot table but keep the evidence-path line. State the omission explicitly so the user knows it was intentional.
- If screenshot capture fails (no display, headless crash), document the reason and link alternative evidence (log file, HTTP trace) rather than silently dropping the requirement.
- Failure comments use the same format with broken-state screenshots (e.g., `before-fix-desktop.png`).

### Lifecycle (Tester, rebuild — when Reviewer bounced for [QA] thread fixes)
1. Read PR review threads; filter `[QA]` prefix.
2. For each unresolved `[QA]` thread: apply fix to test files → resolve thread via `gh api graphql resolveReviewThread`.
3. Re-run full test suite for the ticket.
4. Save evidence to `runs/issue-<N>-qa-v<N+1>/`.
5. Commit + push. Verify ALL `[QA]` threads resolved.
6. Post 🔍 PR + issue comments. Move QA → Review.

### Failure → `root-cause-hash:` line required
Hash lane = `qa`. Same input definition as super-build.

### Block/Skip exits use the §4 mandatory template
Same rule as super-build.
