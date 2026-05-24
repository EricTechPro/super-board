# super-board lint — 7-phase interactive ticket clarifier

> Reference for the `super-board lint` verb. See spec §6 of
> `docs/superpowers/specs/2026-05-21-super-board-design.md` for the full
> design rationale. This file is the worker-facing playbook.

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
   Variant: <full|qa-only>
   Columns to scan: Ready, [Building,] QA, Review
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

## Lint criteria — 12-criterion table

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
| 11 | Out-of-scope vs PROJECT.md | Backend AC for a URL-only QA project | Move to Skipped or rewrite |
| 12 | Sub-agent ambiguity flag | "this could mean ≥2 different things" | Surface both interpretations |

---

## Phase 4 — skill routing

| Flagged pattern | Skill dispatched |
|---|---|
| QA ticket, vague test surface | `qa-test-planner` |
| Feature ticket, undefined UX | `gstack:shape` |
| Copy / microcopy / error message AC | `gstack:clarify` |
| Bug ticket, no repro steps | `investigate` |
| Issue needing fundamental rethink (criteria #10, #11) | `superpowers:brainstorming` |
| Issue with multiple interpretations (criterion #12) | `gsd-discuss-phase` |
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
   • 0 moved to Skipped

💾 All changes saved to GitHub (no local commits needed).
🔄 Reset this session, then run `super-board run` to start the loop.
```

---

## Behaviors

- **Idempotent** — re-running on already-clear issues is silent.
- **Resumable** — Ctrl-C anywhere is safe; re-run lint to continue.
- **Walks active-pipeline columns only** — Ready + (Building) + QA + Review. Skips Done/Blocked/Skipped.
- **No local file writes** during Phase 4 — all state lives on GitHub issues. Session-reset is safe.

---

## Worker self-check (mandatory before exit)

Before declaring lint complete, the worker MUST verify all three:

- [ ] `docs/super-board/pre-flight.md` exists and lists every credential / tool / env signal encountered while scanning issues + PROJECT.md.
- [ ] Every issue in active-pipeline columns (Ready, Building if present, QA, Review) either:
  - has a populated `## Acceptance Criteria` section that passes all 12 criteria, OR
  - carries a `🤷 Skipped` comment explaining why it was deferred, OR
  - carries a `🛡 Blocked` comment naming the human-gated blocker.
- [ ] No issue is left in an in-between state (flagged but not resolved, partially edited, or awaiting user input that never came).

If any check fails, do **not** print the Phase 7 success banner. Re-enter the loop on the unresolved issues, or halt with a clear "N issues still need attention" message so the user can re-run `super-board lint`.
