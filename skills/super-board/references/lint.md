# super-board lint — 7-phase interactive ticket clarifier

> Reference for the `super-board lint` verb. This file is the worker-facing playbook.

**Where it runs:** current Claude Code session. Interactive. Single-pass.
**Purpose:** clarify issues so a headless worker won't hallucinate. Every
active-pipeline issue must have testable acceptance criteria.

All clarifications are saved to GitHub via `gh issue edit` /
`gh issue comment` — **no local file writes** during the per-issue loop.
The only local artifact this verb produces is
`docs/super-board/pre-flight.md` in Phase 6.

---

## Intro shown when lint starts

```
🧹 super-board lint
─────────────────────────────────────────────────────────
Purpose: clarify your tickets BEFORE the autonomous loop runs.

Why: when `super-board run` dispatches headless workers, those workers
can't ask you questions. If an issue is vague, they hallucinate.
Lint catches vague issues now, while you can still answer.

Progress: ✅ onboard  →  🧹 lint (you are here)  →  🤖 run (next)
─────────────────────────────────────────────────────────
```

---

## Phases 0–7

```
PHASE 0 — Pick config
  ├─ 0 configs → halt: "Run `super-board onboard` first."
  ├─ 1 config → use it (1-liner confirm)
  └─ 2+ configs → list by description, ask which

PHASE 1 — Confirm GitHub project
  "🎯 Linting: <project title> (#<number>) under <owner>
   Columns to scan: Ready, Building, QA, Review
   Labels: qa · bug · feature (a card with none is built; lint proposes one)
   Proceed? (y/n)"

PHASE 2 — Read the project, then ask "do I understand it?"
  ├─ Fetch all issues in active-pipeline columns
  ├─ Read PROJECT.md (if exists) + recent commits + repo README (if local)
  ├─ Sub-agent synthesizes a project summary (1-2 sentences)
  └─ Ask the user: "Anything I'm missing or got wrong?"

PHASE 3 — Scan summary (flag only what needs work)
  ├─ Score each issue (silent pass): clear / vague / missing
  ├─ Show one-line goal: "🎯 What this board is collectively trying to do: ..."
  └─ Show flagged count + IDs: "4 issues need your attention: #12, #19, #23, #31"

PHASE 4 — Deep-dive flagged issues (skill-routed, PM voice, one at a time)

PHASE 5 — Per-issue summary

PHASE 6 — Pre-flight readiness (credentials, tools, env)

PHASE 7 — Final summary + session-reset nudge
```

---

## Phase 0 edge cases

| State | Lint's response |
|---|---|
| 0 configs exist | Halt: "Run `super-board onboard` first." |
| 1 config, project still on GitHub | Use it, 1-liner confirm |
| 2+ configs | List by description, ask which |
| Config exists but project deleted | Halt: "Project #N no longer exists. Run `super-board onboard` to recreate." |
| Config exists, columns missing | Halt: "Columns missing: [X, Y]. Run `super-board onboard` to repair." |
| User deleted config but project still on GitHub | Nothing to load; user runs `onboard` and picks "use existing project". |

---

## Lint criteria — 18-criterion table

An issue is flagged if any of these apply. An issue can fail multiple criteria; all firing criteria are surfaced in Phase 4.

| # | Criterion | Example fail | What lint suggests |
|---|---|---|---|
| 1 | No `## Acceptance Criteria` section | Body has description only | Draft 3-5 ACs from title + body + PROJECT.md |
| 2 | ACs section empty | `## Acceptance Criteria\n\n(none yet)` | Same as #1 |
| 3 | Unmeasurable adjectives | "snappier", "polished", "modern" | Replace with measurable threshold |
| 4 | Subjective verbs, no observable outcome | "improve UX", "make it pop" | Rewrite as user-observable behavior |
| 5 | Vague quantifiers, no unit | "loads quickly", "many results" | Add unit/threshold |
| 6 | Missing trigger + outcome pair | "chat works" | Reformat as Given/When/Then |
| 7 | Missing test surface | QA issue with no URL/page; Build issue with no file hint | Add the surface |
| 8 | Ambiguous scope (`etc.`, `TODO`, `TBD`) | "Tabs, dropdowns, modals, etc." | Enumerate or split |
| 9 | Multiple unrelated features bundled (>3 disconnected ACs) | Auth + billing + UI polish in one ticket | Recommend splitting |
| 10 | Title ↔ body mismatch | Title says login, body says signup | Ask which is correct |
| 11 | Out-of-scope vs PROJECT.md | AC for a feature the project explicitly excludes | Drop it (close as not planned, Done, 🤷) or rewrite |
| 12 | Sub-agent ambiguity flag | "this could mean ≥2 different things" | Surface both interpretations |
| 13 | `## Blocked by` missing, empty, or unparseable | No section; or `- None — but #26 must merge first` | Rewrite to `- #N — why` bullets, or a bare `- None.` |
| 14 | An AC proves behaviour against a fake, and no card owns the real thing | "proven with a fake repository, no database" | Name the ticket that builds it, or offer to file one |
| 15 | Too big: likely over ~400 changed lines (`merge_policy.auto_max_lines`), or spans many areas | "Add billing page, webhook handler, admin UI and email templates" | Hold with ❓ and split via `/to-tickets` into vertical slices |
| 16 | Ticket sections missing (writing-standard.md § 3): `## Problem`, `## Context`, `## Fix`, `## Risk` — and `## Evidence` (the folded 12-row table) on a bug | Body has "What to build" and ACs only | Rewrite into the ticket format; draft Problem/Fix from the body, ask for Who and Risk |
| 17 | Acceptance Criteria not a checklist | ACs as prose or plain `-` bullets | Rewrite as `- [ ] <checkable outcome>`, one per line |
| 18 | Context steps not lettered under Where, more than one step per line, or chained with arrows | "Where: /x — sign in → open Receipts → drop file" | Rewrite as `- **Where:** …` then `  - a. Sign in` / `  - b. …`, one per line; embed the screenshot (raw URL pinned to a sha), never link it |

---

## Criteria 13 and 14 — the two that cost the most

Both were added on 2026-08-20 after a real board stalled on them. They are different from 1–12:
those judge whether a **human** can act on a ticket, these judge whether the **loop** can.

**13 — the dependency line.** The wave planner reads `## Blocked by` to decide what may start and to
sweep cards whose blockers have closed. Three shapes defeat it, and all three were on the board:

| On the ticket | A human reads | The planner reads |
|---|---|---|
| *(no section at all)* | "probably nothing blocks it" | unknown — fail safe, never starts |
| `## Blocked by` then nothing | "nothing blocks it" | unknown — fail safe, never starts |
| `- None — but #26 must merge first` | **one blocker** | **no blockers** — starts it early |

The third is the dangerous one, because the two readings disagree and the planner's is the one that
acts. Note the source: the `to-tickets` template offers *"None — can start immediately"* as its
example, so this shape is produced by following the instructions. Lint must catch it on the way in.

Accept exactly two forms. Bullets — `- #32 — the price feed` — or a single `- None.` on its own.
Explanation goes in a blockquote **below** the bullet, never on it.

**14 — the fake with no follow-up.** A ticket may legitimately close having proved its behaviour
against a stub; that is often the right scope. What must not happen is the stub reaching the base
branch with no card owning the real implementation. On the same board, a route shipped proven
against a fake repository — its own stated sixth criterion, correct and deliberate — and the real
writer had no ticket number. It was found two tickets later when another card's Tester hit the wall,
and filed by hand.

When an AC contains *fake*, *stub*, *mock*, `notBuiltYet`, or "no database / no network" as the
proof method, ask one question: **which card builds the real one?** A number is an answer. "Later"
is not.

## Criterion 15 — too big (small PRs by design)

Small pull requests are a design goal: each ticket should land as one PR under the merge size cap
(`merge_policy.auto_max_lines`, default 400 changed lines; lockfiles, generated files, snapshots and
migration SQL do not count). A PR over the cap is never auto-merged — it parks in Blocked 🙋 as a
"big PR". Catching it at lint time is cheaper than splitting a finished branch.

Flag a ticket as **too big** when either holds:

- **Likely over the cap** — estimate from the ACs and the files they imply: many new screens or
  endpoints, a new module plus its UI plus its tests, or "and" chaining unrelated deliverables.
- **Spans many areas** — touches three or more separate areas (say UI, API, database, background
  job, email) where each could ship and be checked alone.

What lint does: hold the ticket with ❓ (Blocked, `block-template.md`, reason "too big — split
first") and offer to split it with `/to-tickets` into vertical slices — each slice thin end to end,
independently mergeable, under the cap, with its own ACs and a `## Blocked by` line. The original
ticket closes, or becomes the first slice, once the user approves the split.

## Phase 4 — skill routing

| Flagged pattern | Skill dispatched |
|---|---|
| QA ticket, vague test surface | `qa-test-planner` |
| Feature ticket, undefined UX | `shape` |
| Copy / microcopy / error message AC | `clarify` |
| Bug ticket, no repro steps | `mattpocock-skills:diagnosing-bugs` |
| Issue needing fundamental rethink (criteria #10, #11) | `mattpocock-skills:grilling` |
| Issue with multiple interpretations (criterion #12) | `mattpocock-skills:grilling` |
| Ticket too big (criterion #15) | `/to-tickets` (split into vertical slices) |
| Ticket format (criteria #16–18) | Inline rewrite into `ticket-format.md` (sub-agent in lint itself) |
| Catch-all (none of above) | Inline draft (sub-agent in lint itself) |

One sub-agent per issue. User stays in control of pacing.

---

## Phase 4 — PM-friendly translation table

| Don't say | Say |
|---|---|
| "Acceptance criteria" | "What we'll check" |
| "AC #2 is non-deterministic" | "Step 2 doesn't say what 'pass' looks like" |
| "TDD-style red-green" | (don't mention) |
| "Happy path coverage" | "The main flow works" |
| "Regression test" | "Make sure it still works for old users" |

Per-issue interaction example:

```
─────────────────────────────────────────────────────────
#19  "Make the chat snappier"             Column: Ready
─────────────────────────────────────────────────────────
🚩 "Snappier" isn't measurable. A worker won't know
   when it's done.

💡 Suggested fix (what we'll check):
   1. First reply shows up in under half a second
   2. Page doesn't jump while reply is streaming
   3. Long messages don't break the layout

[a] approve   [e] edit   [b] block   [k] skip   [s] leave as-is
> _
```

---

## Phase 6 — pre-flight format

Sub-agent scans all linted issues + PROJECT.md to extract operational requirements:

```
🔑 Credentials the loop will need:
   [ ] OPENAI_API_KEY (issues #14, #19)
   [ ] Test user login: testuser@example.com (issue #23)
   [ ] Stripe test secret key (issue #31)

🛠  Tools the loop will need:
   [✓] gh CLI authenticated (verified)
   [ ] Playwright Chromium → run: `npx playwright install chromium`
   [✓] Node 20+ (verified)

🌐 Environment:
   [✓] Target URL reachable: https://chatbot.ai-sdk.dev (200 OK)
   [ ] .env.local has OPENAI_API_KEY set
```

Saved to `docs/super-board/pre-flight.md`. Each `[ ]` is a halt gate for `super-board run` — the loop refuses to start until all items are `[✓]`.

> Each `[ ]` is a halt gate for `super-board run` — the loop refuses to start until all items are `[✓]`.

---

## Phase 7 — final summary template

```
✅ Lint complete:
   • 23 already clear
   • 3 ACs added (approved)
   • 1 moved to Blocked
   • 0 dropped (closed as not planned)

💾 All changes saved to GitHub (no local commits needed).
🔄 Reset this session, then run `super-board run` to start the loop.
```

---

## Behaviors

- **Idempotent** — re-running on already-clear issues is silent.
- **Resumable** — Ctrl-C anywhere is safe; re-run lint to continue.
- **Labels** — a card with no `qa` / `bug` / `feature` label gets one proposed with its AC fix (`qa` only when the ACs test what already exists and change nothing; it routes the card past Building). Applied on approve, like the AC edits.
- **Walks active-pipeline columns only** — Ready + Building + QA + Review. Skips Backlog/Done/Blocked.
- **No local file writes** during Phase 4 — all state lives on GitHub issues. Session-reset is safe.

---

## Worker self-check (mandatory before exit)

Before declaring lint complete, the worker MUST verify all three:

- [ ] `docs/super-board/pre-flight.md` exists and lists every credential / tool / env signal encountered while scanning issues + PROJECT.md.
- [ ] Every issue in active-pipeline columns (Ready, Building, QA, Review) either:
  - has a populated `## Acceptance Criteria` section that passes all 18 criteria, OR
  - was dropped on purpose (closed as not planned, Done, `🤷 dropped` comment), OR
  - carries a `🛡 Blocked` comment naming the human-gated blocker.
- [ ] No issue is left in an in-between state (flagged but not resolved, partially edited, or awaiting user input that never came).

If any check fails, do **not** print the Phase 7 success banner. Re-enter the loop on the unresolved issues, or halt with a clear "N issues still need attention" message so the user can re-run `super-board lint`.
